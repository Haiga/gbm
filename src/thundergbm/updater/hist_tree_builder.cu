//
// Created by ss on 19-1-20.
//
#include "thundergbm/updater/hist_tree_builder.h"

#include "thundergbm/util/cub_wrapper.h"
#include "thundergbm/util/device_lambda.cuh"
#include "thrust/iterator/counting_iterator.h"
#include "thrust/iterator/transform_iterator.h"
#include "thrust/iterator/discard_iterator.h"
#include "thrust/sequence.h"
#include "thrust/binary_search.h"

void HistTreeBuilder::InternalShard::get_bin_ids(const SparseColumns &columns) {
    using namespace thrust;
    int n_column = columns.n_column;
    int nnz = columns.nnz;
    auto cut_row_ptr = cut.cut_row_ptr.device_data();
    auto cut_points_ptr = cut.cut_points_val.device_data();
    auto csc_val_data = columns.csc_val.device_data();
    SyncArray<unsigned char> bin_id;
    bin_id.resize(columns.nnz);
    auto bin_id_data = bin_id.device_data();
    int n_block = fminf((nnz / n_column - 1) / 256 + 1, 4 * 56);
    {
        auto lowerBound = [=]__device__(const float_type *search_begin, const float_type *search_end, float_type val) {
            const float_type *left = search_begin;
            const float_type *right = search_end;

            while (left != right) {
                const float_type *mid = left + (right - left) / 2;
                if (*mid <= val)
                    right = mid;
                else left = mid + 1;
            }
            return left;
        };
        TIMED_SCOPE(timerObj, "binning");
        device_loop_2d(n_column, columns.csc_col_ptr.device_data(), [=]__device__(int cid, int i) {
            auto search_begin = cut_points_ptr + cut_row_ptr[cid];
            auto search_end = cut_points_ptr + cut_row_ptr[cid + 1];
            auto val = csc_val_data[i];
            bin_id_data[i] = lowerBound(search_begin, search_end, val) - search_begin;
        }, n_block);
    }

    auto max_num_bin = param.max_num_bin;
    dense_bin_id.resize(stats.n_instances * n_column);
    auto dense_bin_id_data = dense_bin_id.device_data();
    auto csc_row_idx_data = columns.csc_row_idx.device_data();
    device_loop(stats.n_instances * n_column, [=]__device__(int i) {
        dense_bin_id_data[i] = max_num_bin;
    });
    device_loop_2d(n_column, columns.csc_col_ptr.device_data(), [=]__device__(int fid, int i) {
        int row = csc_row_idx_data[i];
        unsigned char bid = bin_id_data[i];
        dense_bin_id_data[row * n_column + fid] = bid;
    }, n_block);
}

void HistTreeBuilder::InternalShard::find_split(int level) {
    TIMED_FUNC(timerObj);
    int n_nodes_in_level = static_cast<int>(pow(2, level));
    int nid_offset = static_cast<int>(pow(2, level) - 1);
    int n_column = columns.n_column;
    int n_partition = n_column * n_nodes_in_level;
    int n_bins = cut.cut_points.size();
    int n_max_nodes = 2 << param.depth;
    int n_max_splits = n_max_nodes * n_bins;
    int n_split = n_nodes_in_level * n_bins;

    LOG(TRACE) << "start finding split";

    //find the best split locally
    {
        using namespace thrust;

        //calculate split information for each split
        SyncArray<GHPair> hist(n_max_splits);
        SyncArray<GHPair> missing_gh(n_partition);
        auto cut_fid_data = cut.cut_fid.device_data();
        auto i2fid = [=] __device__(int i) { return cut_fid_data[i % n_bins]; };
        auto hist_fid = make_transform_iterator(counting_iterator<int>(0), i2fid);
        {
            {
                TIMED_SCOPE(timerObj, "build hist");
                {
                    size_t
                    smem_size = n_bins * sizeof(GHPair);
                    LOG(DEBUG) << "shared memory size = " << smem_size / 1024.0 << " KB";
                    if (n_nodes_in_level == 1) {
                        //root
                        auto hist_data = hist.device_data();
                        auto cut_row_ptr_data = cut.cut_row_ptr.device_data();
                        auto gh_data = stats.gh_pair.device_data();
                        auto dense_bin_id_data = dense_bin_id.device_data();
                        auto max_num_bin = param.max_num_bin;
                        auto n_instances = stats.n_instances;
                        if (smem_size > 48 * 1024) {
                            device_loop(stats.n_instances * n_column, [=]__device__(int i) {
                                int iid = i / n_column;
                                int fid = i % n_column;
                                unsigned char bid = dense_bin_id_data[iid * n_column + fid];
                                if (bid != max_num_bin) {
                                    int feature_offset = cut_row_ptr_data[fid];
                                    const GHPair src = gh_data[iid];
                                    GHPair &dest = hist_data[feature_offset + bid];
                                    atomicAdd(&dest.g, src.g);
                                    atomicAdd(&dest.h, src.h);
                                }
                            });
                        } else {
                            anonymous_kernel([=]__device__() {
                                extern __shared__ GHPair local_hist[];
                                for (int i = threadIdx.x; i < n_bins; i += blockDim.x) {
                                    local_hist[i] = 0;
                                }
                                __syncthreads();
                                for (int i = blockIdx.x * blockDim.x + threadIdx.x;
                                     i < n_instances * n_column; i += blockDim.x * gridDim.x) {
                                    int iid = i / n_column;
                                    int fid = i % n_column;
                                    unsigned char bid = dense_bin_id_data[iid * n_column + fid];
                                    if (bid != max_num_bin) {
                                        int feature_offset = cut_row_ptr_data[fid];
                                        const GHPair src = gh_data[iid];
                                        GHPair &dest = local_hist[feature_offset + bid];
                                        atomicAdd(&dest.g, src.g);
                                        atomicAdd(&dest.h, src.h);
                                    }
                                }
                                __syncthreads();
                                for (int i = threadIdx.x; i < n_bins; i += blockDim.x) {
                                    GHPair &dest = hist_data[i];
                                    GHPair src = local_hist[i];
                                    atomicAdd(&dest.g, src.g);
                                    atomicAdd(&dest.h, src.h);
                                }
                            }, smem_size);
                        }
                    } else {
                        //otherwise
                        SyncArray<int> node_idx(stats.n_instances);
                        SyncArray<int> node_ptr(n_nodes_in_level + 1);
                        {
                            TIMED_SCOPE(timerObj, "data partitioning");
                            SyncArray<int> nid4sort(stats.n_instances);
                            nid4sort.copy_from(stats.nid);
                            sequence(cuda::par, node_idx.device_data(), node_idx.device_end(), 0);
                            cub_sort_by_key(nid4sort, node_idx);
                            auto counting_iter = make_counting_iterator < int > (nid_offset);
                            node_ptr.host_data()[0] =
                                    lower_bound(cuda::par, nid4sort.device_data(), nid4sort.device_end(), nid_offset) -
                                    nid4sort.device_data();

                            upper_bound(cuda::par, nid4sort.device_data(), nid4sort.device_end(), counting_iter,
                                        counting_iter + n_nodes_in_level, node_ptr.device_data() + 1);
                            LOG(DEBUG) << "node ptr = " << node_ptr;
                            cudaDeviceSynchronize();
                        }

                        for (int i = 0; i < n_nodes_in_level / 2; ++i) {
                            int nid0_to_compute = i * 2;
                            int nid0_to_substract = i * 2 + 1;
                            auto node_ptr_data = node_ptr.host_data();
                            int n_ins_left = node_ptr_data[nid0_to_compute + 1] - node_ptr_data[nid0_to_compute];
                            int n_ins_right = node_ptr_data[nid0_to_substract + 1] - node_ptr_data[nid0_to_substract];
                            if (max(n_ins_left, n_ins_right) == 0) continue;
                            if (n_ins_left > n_ins_right)
                                swap(nid0_to_compute, nid0_to_substract);

                            //compute
                            {
                                int nid0 = nid0_to_compute;
                                auto idx_begin = node_ptr.host_data()[nid0];
                                auto idx_end = node_ptr.host_data()[nid0 + 1];
                                auto node_idx_data = node_idx.device_data();
                                auto hist_data = hist.device_data() + nid0 * n_bins;
                                auto cut_row_ptr_data = cut.cut_row_ptr.device_data();
                                auto gh_data = stats.gh_pair.device_data();
                                auto dense_bin_id_data = dense_bin_id.device_data();
                                auto max_num_bin = param.max_num_bin;
                                if (smem_size > 48 * 1024) {
                                    device_loop((idx_end - idx_begin) * n_column, [=]__device__(int i) {
                                        int iid = node_idx_data[i / n_column + idx_begin];
                                        int fid = i % n_column;
                                        unsigned char bid = dense_bin_id_data[iid * n_column + fid];
                                        if (bid != max_num_bin) {
                                            int feature_offset = cut_row_ptr_data[fid];
                                            const GHPair src = gh_data[iid];
                                            GHPair &dest = hist_data[feature_offset + bid];
                                            atomicAdd(&dest.g, src.g);
                                            atomicAdd(&dest.h, src.h);
                                        }
                                    });
                                } else {
                                    anonymous_kernel([=]__device__() {
                                        extern __shared__ GHPair local_hist[];
                                        for (int i = threadIdx.x; i < n_bins; i += blockDim.x) {
                                            local_hist[i] = 0;
                                        }
                                        __syncthreads();

                                        for (int i = blockIdx.x * blockDim.x + threadIdx.x;
                                             i < (idx_end - idx_begin) * n_column; i += blockDim.x * gridDim.x) {
                                            int iid = node_idx_data[i / n_column + idx_begin];
                                            int fid = i % n_column;
                                            unsigned char bid = dense_bin_id_data[iid * n_column + fid];
                                            if (bid != max_num_bin) {
                                                int feature_offset = cut_row_ptr_data[fid];
                                                const GHPair src = gh_data[iid];
                                                GHPair &dest = local_hist[feature_offset + bid];
                                                atomicAdd(&dest.g, src.g);
                                                atomicAdd(&dest.h, src.h);
                                            }
                                        }
                                        __syncthreads();
                                        for (int i = threadIdx.x; i < n_bins; i += blockDim.x) {
                                            GHPair &dest = hist_data[i];
                                            GHPair src = local_hist[i];
                                            atomicAdd(&dest.g, src.g);
                                            atomicAdd(&dest.h, src.h);
                                        }
                                    }, smem_size);
                                }
                            }

                            //substract
                            {
                                auto hist_data_computed = hist.device_data() + nid0_to_compute * n_bins;
                                auto hist_data_to_compute = hist.device_data() + nid0_to_substract * n_bins;
                                auto father_hist_data = last_hist.device_data() + (nid0_to_substract / 2) * n_bins;
                                device_loop(n_bins, [=]__device__(int i) {
                                    hist_data_to_compute[i] = father_hist_data[i] - hist_data_computed[i];
                                });
                            }
//                            PERFORMANCE_CHECKPOINT(timerObj);
                        }
                    }
                    last_hist.copy_from(hist);
                    cudaDeviceSynchronize();
                }
                LOG(DEBUG) << "hist new = " << hist;
                LOG(DEBUG) << "cutfid = " << cut.cut_fid;
                inclusive_scan_by_key(cuda::par, hist_fid, hist_fid + n_split,
                                      hist.device_data(), hist.device_data());
                LOG(DEBUG) << hist;

                auto nodes_data = tree.nodes.device_data();
                auto missing_gh_data = missing_gh.device_data();
                auto cut_row_ptr = cut.cut_row_ptr.device_data();
                auto hist_data = hist.device_data();
                device_loop(n_partition, [=]__device__(int pid) {
                    int nid0 = pid / n_column;
                    int nid = nid0 + nid_offset;
                    if (!nodes_data[nid].splittable()) return;
                    int fid = pid % n_column;
                    if (cut_row_ptr[fid + 1] != cut_row_ptr[fid]) {
                        GHPair node_gh = hist_data[nid0 * n_bins + cut_row_ptr[fid + 1] - 1];
                        missing_gh_data[pid] = nodes_data[nid].sum_gh_pair - node_gh;
                    }
                });
                LOG(DEBUG) << missing_gh;
            }
        }
        //calculate gain of each split
        SyncArray<float_type> gain(n_max_splits);
        {
//            TIMED_SCOPE(timerObj, "calculate gain");
            auto compute_gain = []__device__(GHPair father, GHPair lch, GHPair rch, float_type min_child_weight,
                    float_type lambda) -> float_type {
                    if (lch.h >= min_child_weight && rch.h >= min_child_weight)
                    return (lch.g * lch.g) / (lch.h + lambda) + (rch.g * rch.g) / (rch.h + lambda) -
            (father.g * father.g) / (father.h + lambda);
                    else
                    return 0;
            };

            const Tree::TreeNode *nodes_data = tree.nodes.device_data();
            GHPair *gh_prefix_sum_data = hist.device_data();
            float_type *gain_data = gain.device_data();
            const auto missing_gh_data = missing_gh.device_data();
            auto ignored_set_data = ignored_set.device_data();
            //for lambda expression
            float_type mcw = param.min_child_weight;
            float_type l = param.lambda;
            device_loop(n_split, [=]__device__(int i) {
                int nid0 = i / n_bins;
                int nid = nid0 + nid_offset;
                int fid = hist_fid[i % n_bins];
                if (nodes_data[nid].is_valid && !ignored_set_data[fid]) {
                    int pid = nid0 * n_column + hist_fid[i];
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
        }

        SyncArray<int_float> best_idx_gain(n_nodes_in_level);
        {
//            TIMED_SCOPE(timerObj, "get best gain");
            auto arg_abs_max = []__device__(const int_float &a, const int_float &b) {
                if (fabsf(get<1>(a)) == fabsf(get<1>(b)))
                    return get<0>(a) < get<0>(b) ? a : b;
                else
                    return fabsf(get<1>(a)) > fabsf(get<1>(b)) ? a : b;
            };

            auto nid_iterator = make_transform_iterator(counting_iterator<int>(0), placeholders::_1 / n_bins);

            reduce_by_key(
                    cuda::par,
                    nid_iterator, nid_iterator + n_split,
                    make_zip_iterator(make_tuple(counting_iterator<int>(0), gain.device_data())),
                    make_discard_iterator(),
                    best_idx_gain.device_data(),
                    thrust::equal_to<int>(),
                    arg_abs_max
            );
            LOG(DEBUG) << n_split;
            LOG(DEBUG) << "best rank & gain = " << best_idx_gain;
        }

        //get split points
        {
            const int_float *best_idx_gain_data = best_idx_gain.device_data();
            auto hist_data = hist.device_data();
            const auto missing_gh_data = missing_gh.device_data();
            auto cut_val_data = cut.cut_points_val.device_data();

            sp.resize(n_nodes_in_level);
            auto sp_data = sp.device_data();
            auto nodes_data = tree.nodes.device_data();

            int column_offset = columns.column_offset;

            auto cut_row_ptr_data = cut.cut_row_ptr.device_data();
            device_loop(n_nodes_in_level, [=]__device__(int i) {
                int_float bst = best_idx_gain_data[i];
                float_type best_split_gain = get<1>(bst);
                int split_index = get<0>(bst);
                if (!nodes_data[i + nid_offset].is_valid) {
                    sp_data[i].split_fea_id = -1;
                    sp_data[i].nid = -1;
                    return;
                }
                int fid = hist_fid[split_index];
                sp_data[i].split_fea_id = fid + column_offset;
                sp_data[i].nid = i + nid_offset;
                sp_data[i].gain = fabsf(best_split_gain);
                sp_data[i].fval = cut_val_data[split_index % n_bins];
                sp_data[i].split_bid = (unsigned char) (split_index % n_bins - cut_row_ptr_data[fid]);
                sp_data[i].fea_missing_gh = missing_gh_data[i * n_column + hist_fid[split_index]];
                sp_data[i].default_right = best_split_gain < 0;
                sp_data[i].rch_sum_gh = hist_data[split_index];
            });
        }
    }

    LOG(DEBUG) << "split points (gain/fea_id/nid): " << sp;
}

void HistTreeBuilder::InternalShard::update_ins2node_id() {
    TIMED_FUNC(timerObj);
    SyncArray<bool> has_splittable(1);
    //set new node id for each instance
    {
//        TIMED_SCOPE(timerObj, "get new node id");
        auto nid_data = stats.nid.device_data();
        const Tree::TreeNode *nodes_data = tree.nodes.device_data();
        has_splittable.host_data()[0] = false;
        bool *h_s_data = has_splittable.device_data();
        int column_offset = columns.column_offset;

        int n_column = columns.n_column;
        auto dense_bin_id_data = dense_bin_id.device_data();
        int max_num_bin = param.max_num_bin;
        device_loop(stats.n_instances, [=]__device__(int iid) {
            int nid = nid_data[iid];
            const Tree::TreeNode &node = nodes_data[nid];
            int split_fid = node.split_feature_id;
            if (node.splittable() && ((split_fid - column_offset < n_column) && (split_fid >= column_offset))) {
                h_s_data[0] = true;
                unsigned char split_bid = node.split_bid;
                unsigned char bid = dense_bin_id_data[iid * n_column + split_fid - column_offset];
                bool to_left = true;
                if ((bid == max_num_bin && node.default_right) || (bid <= split_bid))
                    to_left = false;
                if (to_left) {
                    //goes to left child
                    nid_data[iid] = node.lch_index;
                } else {
                    //right child
                    nid_data[iid] = node.rch_index;
                }
            }
        });
    }
    LOG(DEBUG) << "new tree_id = " << stats.nid;
    has_split = has_splittable.host_data()[0];
}

void HistTreeBuilder::split_point_all_reduce(int depth, vector<InternalShard> &shards) {
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

void HistTreeBuilder::ins2node_id_all_reduce(vector<InternalShard> &shards) {
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
    for_each_shard(shards, [&](InternalShard &shard) {
        shard.stats.nid.copy_from(shards.front().stats.nid);
    });
}

const MSyncArray<float_type>& HistTreeBuilder::get_y_predict() {
    return y_predict;
}

vector<Tree> HistTreeBuilder::build_approximate(const MSyncArray<GHPair> &gradients) {
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
                ins2node_id_all_reduce(shards);
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

void HistTreeBuilder::init(const DataSet &dataset, const GBMParam &param) {
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
        shard.cut.get_cut_points2(shard.columns, param.max_num_bin, shard.stats.n_instances);
        shard.last_hist.resize((2 << param.depth) * shard.cut.cut_points.size());
        shard.get_bin_ids(shard.columns);
        y_predict[shard.rank] = SyncArray<float_type>(shard.stats.y_predict.size());
        y_predict[shard.rank].set_host_data(shard.stats.y_predict.host_data());
        y_predict[shard.rank].set_device_data(shard.stats.y_predict.device_data());
    });

    for (int i = 0; i < param.n_device; ++i) {
        v_columns[i].release();
    }
    SyncMem::clear_cache();
}
