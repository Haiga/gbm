//
// Created by ss on 19-1-17.
//

#ifndef THUNDERGBM_BOOSTER_H
#define THUNDERGBM_BOOSTER_H

#include <thundergbm/objective/objective_function.h>
#include <thundergbm/metric/metric.h>
#include <thundergbm/updater/function_builder.h>
#include <thundergbm/updater/hist_tree_builder.h>
#include <thundergbm/updater/exact_tree_builder.h>
#include "thundergbm/common.h"
#include "syncarray.h"
#include "tree.h"

class Booster {
public:
    void init(const DataSet &dataSet, const GBMParam &param);

    void boost(vector<vector<Tree>> &boosted_model);

private:
    MSyncArray<GHPair> gradients;
    std::unique_ptr<ObjectiveFunction> obj;
    std::unique_ptr<Metric> metric;
    MSyncArray<float_type> y;
    std::unique_ptr<FunctionBuilder> fbuilder;
    GBMParam param;
    int n_devices;
};

void Booster::init(const DataSet &dataSet, const GBMParam &param) {
    this->param = param;
    fbuilder.reset(FunctionBuilder::create(param.tree_method));
    fbuilder->init(dataSet, param);
    obj.reset(ObjectiveFunction::create(param.objective));
    obj->configure(param, dataSet);
    metric.reset(Metric::create(obj->default_metric_name()));
    metric->configure(param, dataSet);

    n_devices = param.n_device;
    int n_outputs = param.num_class * dataSet.n_instances();
    gradients = MSyncArray<GHPair>(n_devices, n_outputs);
    y = MSyncArray<float_type>(n_devices, dataSet.n_instances());

    DO_ON_MULTI_DEVICES(n_devices, [&](int device_id) {
        y[device_id].copy_from(dataSet.y.data(), dataSet.n_instances());
    });
}

void Booster::boost(vector<vector<Tree>> &boosted_model) {
    TIMED_FUNC(timerObj);
    //update gradients
    DO_ON_MULTI_DEVICES(n_devices, [&](int device_id) {
        obj->get_gradient(y[device_id], fbuilder->get_y_predict()[device_id], gradients[device_id]);
    });
    PERFORMANCE_CHECKPOINT(timerObj);
    //build new model/approximate function
    boosted_model.push_back(fbuilder->build_approximate(gradients));

    PERFORMANCE_CHECKPOINT(timerObj);
    //show metric on training set
    LOG(INFO) << metric->get_name() << " = " << metric->get_score(fbuilder->get_y_predict().front());
}

#endif //THUNDERGBM_BOOSTER_H
