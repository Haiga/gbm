//
// Created by zeyi on 1/12/19.
//

#include "thundergbm/predictor.h"
#include <thundergbm/metric/metric.h>
#include "thundergbm/util/device_lambda.cuh"

void Predictor::predict(GBMParam& model_param, vector<vector<Tree>> &boosted_model, DataSet &dataSet){
    int n_instances = dataSet.n_instances();
    int n_feature = dataSet.n_features();
    SyncArray<float_type> y_predict(n_instances);
    y_predict.resize(n_instances);
    auto predict_data = y_predict.device_data();

    //the whole model to an array
    int num_iter = boosted_model.size();
    int num_tree = boosted_model[0].size();
    int num_node = boosted_model[0][0].nodes.size();
    int total_num_node = num_iter * num_tree * num_node;
    SyncArray<Tree::TreeNode> model(total_num_node);
    auto model_data = model.host_data();
    int tree_cnt = 0;
    for(auto &vtree:boosted_model) {
        for(auto &t:vtree) {
            memcpy(model_data + num_node * tree_cnt, t.nodes.host_data(), sizeof(Tree::TreeNode) * num_node);
            tree_cnt++;
        }
    }

    int max_num_val = 1024 * 1024 * 1024;//use 4GB memory
    int num_batch = (n_instances * n_feature + max_num_val - 1) / max_num_val;
    int ave_batch_size = n_instances / num_batch;
    for(int batch_id = 0; batch_id < num_batch; batch_id++) {
        //fill dense
        int row_start_pos = dataSet.csr_row_ptr[batch_id * ave_batch_size];
        int row_end_pos;
        int num_ins_batch = ave_batch_size;
        if(batch_id == num_batch - 1){//last batch
            row_end_pos = dataSet.csr_val.size();
            num_ins_batch = n_instances - ave_batch_size * (num_batch - 1);
        }
        else {
            row_end_pos = dataSet.csr_row_ptr[(batch_id + 1) * ave_batch_size];
        }
        int batch_num_val = row_end_pos - row_start_pos;
        SyncArray<float_type> batch_ins(n_feature * num_ins_batch);
        SyncArray<int> batch_col_idx(batch_num_val);
        SyncArray<float_type> batch_val(batch_num_val);
        SyncArray<int> batch_row_ptr(num_ins_batch + 1);
        batch_col_idx.copy_from(dataSet.csr_col_idx.data() + row_start_pos, batch_num_val);
        batch_val.copy_from(dataSet.csr_val.data() + row_start_pos, batch_num_val);
        batch_row_ptr.copy_from(dataSet.csr_row_ptr.data() + batch_id * ave_batch_size, num_ins_batch + 1);
        auto ins_data = batch_ins.device_data();
        auto col_idx_data = batch_col_idx.device_data();
        auto val_data = batch_val.device_data();
        auto row_ptr_data = batch_row_ptr.device_data();
        //a GPU block for an instance
        device_loop_2d(num_ins_batch, row_ptr_data, [=] __device__(int iid, int vid) {
            int fid = col_idx_data[vid - row_start_pos];
            ins_data[iid * n_feature + fid] = val_data[vid - row_start_pos];
        });
        cudaDeviceSynchronize();

        //prediction
        auto model_device_data = model.device_data();
        auto ins_device_data = batch_ins.device_data();
        device_loop(num_ins_batch, [=]__device__(int i) {
            //get next child
            auto get_next_child = [&](Tree::TreeNode &node, float_type feaValue){
                if(feaValue == 0){//this is a missing value
                    if(node.default_right == false)
                        return node.lch_index;
                    else
                        return node.rch_index;
                }

                if(feaValue < node.split_value)
                    return node.lch_index;
                else
                    return node.rch_index;
            };

            auto ins = ins_device_data + i * n_feature;
            int iid = ave_batch_size * batch_id + i;
            for (int iter = 0; iter < num_iter; iter++) {
                float_type ave_val = 0;//average predicted value
                for (int t = 0; t < num_tree; t++) {//one iteration may have multiple trees (e.g., boosted R. Forests)
                    const Tree::TreeNode *node_data = model_device_data + iter * num_tree * num_node + t * num_node;
                    Tree::TreeNode curNode = node_data[0];
                    int cur_nid = 0; //node id
                    while (!curNode.is_leaf) {
                        int fid = curNode.split_feature_id;
                        cur_nid = get_next_child(curNode, ins[fid]);
                        curNode = node_data[cur_nid];
                    }
                    ave_val += node_data[cur_nid].base_weight;
                }
                ave_val = ave_val / num_tree;
                predict_data[iid] += ave_val;
            }//end all tree prediction
        });
    }

    //convert the aggregated values to labels, probabilities or ranking scores.
    std::unique_ptr<ObjectiveFunction> obj;
    obj.reset(ObjectiveFunction::create(model_param.objective));
    obj->configure(model_param, dataSet);
    obj->predict_transform(y_predict);

    //compute metric
    std::unique_ptr<Metric> metric;
    metric.reset(Metric::create(obj->default_metric_name()));
    metric->configure(model_param, dataSet);
    LOG(INFO) << metric->get_name().c_str() << "=" << metric->get_score(y_predict);
}