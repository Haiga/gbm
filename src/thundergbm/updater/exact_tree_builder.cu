//
// Created by ss on 19-1-20.
//
#include "thundergbm/updater/exact_tree_builder.h"

#include "thundergbm/util/cub_wrapper.h"
#include "thundergbm/util/device_lambda.cuh"
#include "thrust/iterator/counting_iterator.h"
#include "thrust/iterator/transform_iterator.h"
#include "thrust/iterator/discard_iterator.h"
#include "thrust/sequence.h"
#include "thrust/binary_search.h"

void ExactTreeBuilder::InternalShard::find_split(int level) {
    TIMED_FUNC(timerObj);
    int n_max_nodes_in_level = static_cast<int>(pow(2, level));
    int nid_offset = static_cast<int>(pow(2, level) - 1);
    int n_column = columns.n_column;
    int n_partition = n_column * n_max_nodes_in_level;
    int nnz = columns.nnz;
    int n_block = std::min((nnz / n_column - 1) / 256 + 1, 32 * 56);

    LOG(TRACE) << "start finding split";

    //find the best split locally
    {
        using namespace thrust;

        //calculate split information for each split
        int n_split;
        SyncArray<GHPair> gh_prefix_sum(nnz);
        SyncArray<GHPair> missing_gh(n_partition);
        SyncArray<int_float> rle_key(nnz);
        if (nnz * 4 > 1.5 * (1 << 30)) rle_key.resize(int(nnz * 0.1));
        auto rle_pid_data = make_transform_iterator(rle_key.device_data(),
                                                    [=]__device__(int_float key) { return get<0>(key); });
        auto rle_fval_data = make_transform_iterator(rle_key.device_data(),
                                                     [=]__device__(int_float key) { return get<1>(key); });
        {

            //gather g/h pairs and do prefix sum
            {
                SyncArray<int> fvid2pid(nnz);
                SyncArray<int> fvid_new2old(nnz);
                {
                    TIMED_SCOPE(timerObj, "find_split - data partitioning");
                    {
                        //input
                        auto *nid_data = stats.nid.device_data();
                        const int *iid_data = columns.csc_row_idx.device_data();

                        LOG(TRACE) << "after using v_stats and columns";
                        //output
                        int *fvid2pid_data = fvid2pid.device_data();
                        device_loop_2d(
                                n_column, columns.csc_col_ptr.device_data(),
                                [=]__device__(int col_id, int fvid) {
                            //feature value id -> instance id -> node id
                            int nid = nid_data[iid_data[fvid]];
                            int pid;
                            //if this node is leaf node, move it to the end
                            if (nid < nid_offset) pid = INT_MAX;//todo negative
                            else pid = col_id * n_max_nodes_in_level + nid - nid_offset;
                            fvid2pid_data[fvid] = pid;
                        },
                        n_block);
                        cudaDeviceSynchronize();
                        LOG(DEBUG) << "fvid2pid " << fvid2pid;
                    }

                    //get feature value id mapping for partition, new -> old
                    {
//                    TIMED_SCOPE(timerObj, "fvid_new2old");
                        sequence(cuda::par, fvid_new2old.device_data(), fvid_new2old.device_end(), 0);

                        //using prefix sum memory for temporary storage
                        cub_sort_by_key(fvid2pid, fvid_new2old, -1, true, (void *) gh_prefix_sum.device_data());
                        LOG(DEBUG) << "sorted fvid2pid " << fvid2pid;
                        LOG(DEBUG) << "fvid_new2old " << fvid_new2old;
                    }
                    cudaDeviceSynchronize();
                }

                //do prefix sum
                {
                    TIMED_SCOPE(timerObj, "find_split - RLE compression");
                    //same feature value in the same part has the same key.
                    auto key_iter = make_zip_iterator(
                            make_tuple(
                                    fvid2pid.device_data(),
                                    make_permutation_iterator(
                                            columns.csc_val.device_data(),
                                            fvid_new2old.device_data())));//use fvid_new2old to access csc_val
                    n_split = reduce_by_key(
                            cuda::par,
                            key_iter, key_iter + nnz,
                            make_permutation_iterator(                   //ins id -> gh pair
                                    stats.gh_pair.device_data(),
                                    make_permutation_iterator(                 //old fvid -> ins id
                                            columns.csc_row_idx.device_data(),
                                            fvid_new2old.device_data())),             //new fvid -> old fvid
                            rle_key.device_data(),
                            gh_prefix_sum.device_data()
                    ).first - rle_key.device_data();
                    CHECK_LE(n_split, rle_key.size());
                    LOG(DEBUG) << "RLE ratio = " << (float) n_split / nnz;

                    //prefix sum
                    inclusive_scan_by_key(
                            cuda::par,
                            rle_pid_data, rle_pid_data + n_split,
                            gh_prefix_sum.device_data(),
                            gh_prefix_sum.device_data());
                    LOG(DEBUG) << "gh prefix sum = " << gh_prefix_sum;
                    cudaDeviceSynchronize();
                }
            }
        }

        //calculate missing value for each partition
        {
            TIMED_SCOPE(timerObj, "find _split - calculate missing value");
            SyncArray<int> pid_ptr(n_partition + 1);
            counting_iterator<int> search_begin(0);
            upper_bound(cuda::par, rle_pid_data, rle_pid_data + n_split, search_begin,
                        search_begin + n_partition, pid_ptr.device_data() + 1);
            LOG(DEBUG) << "pid_ptr = " << pid_ptr;

            auto pid_ptr_data = pid_ptr.device_data();
            auto rle_key_data = rle_key.device_data();
            float_type rt_eps = param.rt_eps;
            {
                SyncArray<float_type> fval(nnz);
                auto fval_data = fval.device_data();
                device_loop(n_split, [=]__device__(int i) {
                    fval_data[i] = rle_fval_data[i];
                });
                device_loop(n_split, [=]__device__(int i) {
                    int pid = rle_pid_data[i];
                    if (pid == INT_MAX) return;
                    float_type f = fval_data[i];
                    if ((pid_ptr_data[pid + 1] - 1) == i)//the last RLE
                        //using "get" to get a modifiable lvalue
                        get<1>(rle_key_data[i]) = (f - fabsf(fval_data[pid_ptr_data[pid]]) - rt_eps);
                    else
                        //FIXME read/write collision
                        get<1>(rle_key_data[i]) = (f + fval_data[i + 1]) * 0.5f;
                });
            }

            const auto gh_prefix_sum_data = gh_prefix_sum.device_data();
            const auto node_data = tree.nodes.device_data();
            auto missing_gh_data = missing_gh.device_data();
            device_loop(n_partition, [=]__device__(int pid) {
                int nid = pid % n_max_nodes_in_level + nid_offset;
                if (pid_ptr_data[pid + 1] != pid_ptr_data[pid])
                    missing_gh_data[pid] =
                            node_data[nid].sum_gh_pair - gh_prefix_sum_data[pid_ptr_data[pid + 1] - 1];
            });
            LOG(DEBUG) << "missing gh = " << missing_gh;
            cudaDeviceSynchronize();
        }

        //calculate gain of each split
        SyncArray<float_type> gain(nnz);
        {
            TIMED_SCOPE(timerObj, "find_split - calculate gain");
            auto compute_gain = []__device__(GHPair father, GHPair lch, GHPair rch, float_type min_child_weight,
                    float_type lambda) -> float_type {
                    if (lch.h >= min_child_weight && rch.h >= min_child_weight)
                    return (lch.g * lch.g) / (lch.h + lambda) + (rch.g * rch.g) / (rch.h + lambda) -
            (father.g * father.g) / (father.h + lambda);
                    else
                    return 0;
            };
            const Tree::TreeNode *nodes_data = tree.nodes.device_data();
            GHPair *gh_prefix_sum_data = gh_prefix_sum.device_data();
            float_type *gain_data = gain.device_data();
            const auto missing_gh_data = missing_gh.device_data();
            auto ignored_set_data = ignored_set.device_data();
            //for lambda expression
            float_type mcw = param.min_child_weight;
            float_type l = param.lambda;
            device_loop(n_split, [=]__device__(int i) {
                int pid = rle_pid_data[i];
                int nid0 = pid % n_max_nodes_in_level;
                int fid = pid / n_max_nodes_in_level;
                int nid = nid0 + nid_offset;
                if (pid != INT_MAX && !ignored_set_data[fid]) {
                    GHPair father_gh = nodes_data[nid].sum_gh_pair;
                    GHPair p_missing_gh = missing_gh_data[pid];
                    GHPair rch_gh = gh_prefix_sum_data[i];
                    float_type default_to_left_gain = max(0.f,
                                                          compute_gain(father_gh, father_gh - rch_gh, rch_gh, mcw, l));
                    rch_gh = rch_gh + p_missing_gh;
                    float_type default_to_right_gain = max(0.f,
                                                           compute_gain(father_gh, father_gh - rch_gh, rch_gh, mcw, l));
                    if (default_to_left_gain > default_to_right_gain)
                        gain_data[i] = default_to_left_gain;
                    else
                        gain_data[i] = -default_to_right_gain;//negative means default split to right
                } else gain_data[i] = 0;
            });
            LOG(DEBUG) << "gain = " << gain;
            cudaDeviceSynchronize();
        }

        //get best gain and the index of best gain for each feature and each node
        SyncArray<int_float> best_idx_gain(n_partition);
        int n_nodes_in_level;
        {
            TIMED_SCOPE(timerObj, "find_split - get best gain");
            auto arg_abs_max = []__device__(const int_float &a, const int_float &b) {
                if (fabsf(get<1>(a)) == fabsf(get<1>(b)))
                    return get<0>(a) < get<0>(b) ? a : b;
                else
                    return fabsf(get<1>(a)) > fabsf(get<1>(b)) ? a : b;
            };

            //reduce to get best split of each node for this feature
            SyncArray<int> feature_nodes_pid(n_partition);
            int n_feature_with_nodes = reduce_by_key(
                    cuda::par,
                    rle_pid_data, rle_pid_data + n_split,
                    make_zip_iterator(make_tuple(counting_iterator<int>(0), gain.device_data())),
                    feature_nodes_pid.device_data(),
                    best_idx_gain.device_data(),
                    thrust::equal_to<int>(),
                    arg_abs_max).second - best_idx_gain.device_data();

            LOG(DEBUG) << "aaa = " << n_feature_with_nodes;
            LOG(DEBUG) << "f n pid" << feature_nodes_pid;
            LOG(DEBUG) << "best rank & gain = " << best_idx_gain;

            auto feature_nodes_pid_data = feature_nodes_pid.device_data();
            device_loop(n_feature_with_nodes, [=]__device__(int i) {
                feature_nodes_pid_data[i] = feature_nodes_pid_data[i] % n_max_nodes_in_level;
            });
            LOG(DEBUG) << "f n pid" << feature_nodes_pid;
            cub_sort_by_key(feature_nodes_pid, best_idx_gain, n_feature_with_nodes);
            LOG(DEBUG) << "f n pid" << feature_nodes_pid;
            LOG(DEBUG) << "best rank & gain = " << best_idx_gain;
            n_nodes_in_level = reduce_by_key(
                    cuda::par,
                    feature_nodes_pid.device_data(), feature_nodes_pid.device_data() + n_feature_with_nodes,
                    best_idx_gain.device_data(),
                    make_discard_iterator(),
                    best_idx_gain.device_data(),
                    thrust::equal_to<int>(),
                    arg_abs_max
            ).second - best_idx_gain.device_data();
            LOG(DEBUG) << "#nodes in level = " << n_nodes_in_level;
            LOG(DEBUG) << "best rank & gain = " << best_idx_gain;
            cudaDeviceSynchronize();
        }

        //get split points
        const int_float *best_idx_gain_data = best_idx_gain.device_data();
        GHPair *gh_prefix_sum_data = gh_prefix_sum.device_data();
        const auto missing_gh_data = missing_gh.device_data();

        sp.resize(n_max_nodes_in_level);
        auto sp_data = sp.device_data();

        int column_offset = columns.column_offset;
        device_loop(n_max_nodes_in_level, [=]__device__(int i) {
            sp_data[i].nid = -1;
        });
        device_loop(n_nodes_in_level, [=]__device__(int i) {
            int_float bst = best_idx_gain_data[i];
            float_type best_split_gain = get<1>(bst);
            int split_index = get<0>(bst);
            int pid = rle_pid_data[split_index];
            if (pid != INT_MAX) {
                int nid0 = pid % n_max_nodes_in_level;
                sp_data[nid0].nid = nid0 + nid_offset;
                sp_data[nid0].split_fea_id = pid / n_max_nodes_in_level + column_offset;
                sp_data[nid0].gain = fabsf(best_split_gain);
                sp_data[nid0].fval = rle_fval_data[split_index];
                sp_data[nid0].fea_missing_gh = missing_gh_data[pid];
                sp_data[nid0].default_right = best_split_gain < 0;
                sp_data[nid0].rch_sum_gh = gh_prefix_sum_data[split_index];
            }
        });
    }

    LOG(DEBUG) << "split points (gain/fea_id/nid): " << sp;
    cudaDeviceSynchronize();
}

void ExactTreeBuilder::InternalShard::update_ins2node_id() {
    SyncArray<bool> has_splittable(1);
    //set new node id for each instance
    {
//        TIMED_SCOPE(timerObj, "get new node id");
        auto nid_data = stats.nid.device_data();
        const int *iid_data = columns.csc_row_idx.device_data();
        const Tree::TreeNode *nodes_data = tree.nodes.device_data();
        const int *col_ptr_data = columns.csc_col_ptr.device_data();
        const float_type *f_val_data = columns.csc_val.device_data();
        has_splittable.host_data()[0] = false;
        bool *h_s_data = has_splittable.device_data();
        int column_offset = columns.column_offset;

        int n_column = columns.n_column;
        int nnz = columns.nnz;
        int n_block = std::min((nnz / n_column - 1) / 256 + 1, 32 * 56);

        LOG(TRACE) << "update ins2node id for each fval";
        device_loop_2d(n_column, col_ptr_data,
                       [=]__device__(int col_id, int fvid) {
            //feature value id -> instance id
            int iid = iid_data[fvid];
            //instance id -> node id
            int nid = nid_data[iid];
            //node id -> node
            const Tree::TreeNode &node = nodes_data[nid];
            //if the node splits on this feature
            if (node.splittable() && node.split_feature_id == col_id + column_offset) {
                h_s_data[0] = true;
                if (f_val_data[fvid] < node.split_value)
                    //goes to left child
                    nid_data[iid] = node.lch_index;
                else
                    //right child
                    nid_data[iid] = node.rch_index;
            }
        }, n_block);

    }
    LOG(DEBUG) << "new tree_id = " << stats.nid;
    has_split = has_splittable.host_data()[0];
}

void ExactTreeBuilder::split_point_all_reduce(int depth, vector<InternalShard> &shards) {
    TIMED_FUNC(timerObj);
    //get global best split of each node
    int n_nodes_in_level = 1 << depth;//2^i
    int nid_offset = (1 << depth) - 1;//2^i - 1
    auto global_sp_data = shards.front().sp.host_data();
    vector<bool> active_sp(n_nodes_in_level);

    for (int device_id = 0; device_id < param.n_device; device_id++) {
        auto local_sp_data = shards[device_id].sp.host_data();
        for (int j = 0; j < shards[device_id].sp.size(); j++) {
            int sp_nid = local_sp_data[j].nid;
            if (sp_nid == -1) continue;
            int global_pos = sp_nid - nid_offset;
            if (!active_sp[global_pos])
                global_sp_data[global_pos] = local_sp_data[j];
            else
                global_sp_data[global_pos] = (global_sp_data[global_pos].gain >= local_sp_data[j].gain)
                                             ?
                                             global_sp_data[global_pos] : local_sp_data[j];
            active_sp[global_pos] = true;
        }
    }
    //set inactive sp
    for (int n = 0; n < n_nodes_in_level; n++) {
        if (!active_sp[n])
            global_sp_data[n].nid = -1;
    }
    for_each_shard(shards, [&](InternalShard &shard) {
        shard.sp.copy_from(shards.front().sp);
    });
    LOG(DEBUG) << "global best split point = " << shards.front().sp;
}

void ExactTreeBuilder::ins2node_id_all_reduce(vector<InternalShard> &shards, int depth) {
    //get global ins2node id
    {
        SyncArray<int> local_ins2node_id(shards.front().stats.n_instances);
        auto local_ins2node_id_data = local_ins2node_id.device_data();
        auto global_ins2node_id_data = shards.front().stats.nid.device_data();
        for (int d = 1; d < param.n_device; d++) {
            local_ins2node_id.copy_from(shards[d].stats.nid);
            device_loop(shards.front().stats.n_instances, [=]__device__(int i) {
                global_ins2node_id_data[i] = (global_ins2node_id_data[i] > local_ins2node_id_data[i]) ?
                                             global_ins2node_id_data[i] : local_ins2node_id_data[i];
            });
        }
    }

    //processing missing value
    {
        int n_nodes_in_level = 1 << depth;//2^i
        int nid_offset = (1 << depth) - 1;//2^i - 1
//        TIMED_SCOPE(timerObj, "process missing value");
        LOG(TRACE) << "update ins2node id for each missing fval";
        auto global_ins2node_id_data = shards.front().stats.nid.device_data();//essential
        auto nodes_data = shards.front().tree.nodes.device_data();//already broadcast above
        device_loop(shards.front().stats.n_instances, [=]__device__(int iid) {
            int nid = global_ins2node_id_data[iid];
            //if the instance is not on leaf node and not goes down
            if (nodes_data[nid].splittable() && nid < nid_offset + n_nodes_in_level) {
                //let the instance goes down
                const Tree::TreeNode &node = nodes_data[nid];
                if (node.default_right)
                    global_ins2node_id_data[iid] = node.rch_index;
                else
                    global_ins2node_id_data[iid] = node.lch_index;
            }
        });
        LOG(DEBUG) << "new nid = " << shards.front().stats.nid;
    }

    //broadcast ins2node id
    for_each_shard(shards, [&](InternalShard &shard) {
        shard.stats.nid.copy_from(shards.front().stats.nid);
    });
}

const MSyncArray<float_type>& ExactTreeBuilder::get_y_predict() {
    return y_predict;
}

void ExactTreeBuilder::init(const DataSet &dataset, const GBMParam &param) {
    FunctionBuilder::init(dataset, param);
    //TODO refactor

    this->param = param;
    //init shards
    int n_device = param.n_device;
    shards = vector<InternalShard>(n_device);
    vector<std::unique_ptr<SparseColumns>> v_columns(param.n_device);
    for (int i = 0; i < param.n_device; ++i) {
        v_columns[i].reset(&shards[i].columns);
        shards[i].rank = i;
    }
    SparseColumns columns;
    columns.from_dataset(dataset);
    columns.to_multi_devices(v_columns);
    y_predict = MSyncArray<float_type>(param.n_device);
    for_each_shard(shards, [&](InternalShard &shard) {
        int n_instances = shard.columns.n_row;
        shard.stats.resize(n_instances);
        shard.stats.y_predict = SyncArray<float_type>(param.num_class * n_instances);
        shard.param = param;

        shard.ignored_set.resize(shard.columns.n_column);
        y_predict[shard.rank] = SyncArray<float_type>(shard.stats.y_predict.size());
        y_predict[shard.rank].set_device_data(shard.stats.y_predict.device_data());
    });

    for (int i = 0; i < param.n_device; ++i) {
        v_columns[i].release();
    }
    SyncMem::clear_cache();
}

vector<Tree> ExactTreeBuilder::build_approximate(const MSyncArray<GHPair> &gradients) {
    vector<Tree> trees(param.num_class);
    TIMED_FUNC(timerObj);
    for (int k = 0; k < param.num_class; ++k) {
        Tree &tree = trees[k];
        for_each_shard(shards, [&](InternalShard &shard) {
            shard.stats.gh_pair.set_device_data(const_cast<GHPair *>(gradients[shard.rank].device_data() + k * shard.stats.n_instances));
            shard.stats.reset_nid();//set nid of all the instances to 0
            //todo multi-class bagging, column sampling
            shard.column_sampling();//RF uses this, and may be used by GBDTs
            if (param.bagging) shard.stats.do_bagging();//obtain a bag of instances
            shard.tree.init(shard.stats, param);//init root node, reserve memory, etc.
        });
        for (int level = 0; level < param.depth; ++level) {
            for_each_shard(shards, [&](InternalShard &shard) {
                shard.find_split(level);
            });
            split_point_all_reduce(level, shards);
            {
                TIMED_SCOPE(timerObj, "apply sp");
                for_each_shard(shards, [&]( InternalShard &shard) {
                    shard.update_tree();
                    shard.update_ins2node_id();
                });
                {
                    LOG(TRACE) << "gathering ins2node id";
                    //get final result of the reset instance id to node id
                    bool has_split = false;
                    for (int d = 0; d < param.n_device; d++) {
                        has_split |= shards[d].has_split;
                    }
                    if (!has_split) {
                        LOG(INFO) << "no splittable nodes, stop";
                        break;
                    }
                }
                ins2node_id_all_reduce(shards, level);
            }
        }
        for_each_shard(shards, [&](Shard &shard) {
            shard.tree.prune_self(param.gamma);
            shard.predict_in_training(k);
        });
        tree.nodes.resize(shards.front().tree.nodes.size());
        tree.nodes.copy_from(shards.front().tree.nodes);
    }
    return trees;
}
