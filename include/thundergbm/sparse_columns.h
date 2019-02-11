//
// Created by shijiashuai on 5/7/18.
//

#ifndef THUNDERGBM_SPARSE_COLUMNS_H
#define THUNDERGBM_SPARSE_COLUMNS_H

#include "syncarray.h"
#include "dataset.h"

class SparseColumns {//one feature corresponding to one column
public:
    SyncArray<float_type> csc_val;
    SyncArray<int> csc_row_idx;
    SyncArray<int> csc_col_ptr;
    int n_column;
    int n_row;
    int column_offset;
    int nnz;

    void from_dataset(const DataSet &dataSet);

    void to_multi_devices(vector<std::unique_ptr<SparseColumns>> &) const;

};
#endif //THUNDERGBM_SPARSE_COLUMNS_H
