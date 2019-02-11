from sklearn.base import BaseEstimator
from sklearn.base import RegressorMixin, ClassifierMixin

ThundergbmBase = BaseEstimator
ThundergbmRegressorBase = RegressorMixin
ThundergbmClassifierBase = ClassifierMixin

import numpy as np
import scipy.sparse as sp

from sklearn.utils import check_X_y, column_or_1d, check_array
from sklearn.utils.validation import _num_samples

from ctypes import *
from os import path, curdir
from sys import platform


dirname = path.dirname(path.abspath(__file__))

if platform == "linux" or platform == "linux2":
    shared_library_name = "libthundergbm.so"
else :
    print ("OS not supported!")
    exit()

if path.exists(path.abspath(path.join(dirname, shared_library_name))):
    lib_path = path.abspath(path.join(dirname, shared_library_name))
else:
    if platform == "linux" or platform == "linux2":
        lib_path = path.join(dirname, '../build/lib/', shared_library_name)

if path.exists(lib_path):
    thundergbm = CDLL(lib_path)
else :
    print ("Please build the library first!")
    exit()

SVM_TYPE = ['c_svc', 'nu_svc', 'one_class', 'epsilon_svr', 'nu_svr']
KERNEL_TYPE = ['linear', 'polynomial', 'rbf', 'sigmoid', 'precomputed']

class TGBMModel(ThundergbmBase, ThundergbmRegressorBase):
    def __init__(self, depth = 6, num_round = 40,
                 n_device = 1, min_child_weight = 1.0, lambda_tgbm = 1.0, gamma = 1.0, max_num_bin = 255,
                 verbose = 0, column_sampling_rate = 1.0, bagging = 0,
                 n_parallel_trees = 1, learning_rate = 1.0, objective = "reg:linear",
                 num_class = 1, path = "../dataset/test_dataset.txt", out_model_name = "tgbm.model",
                 in_model_name = "tgbm.model", tree_method = "auto"):
        self.depth = depth
        self.n_trees = num_round
        self.n_device = n_device
        self.min_child_weight = min_child_weight
        self.lambda_tgbm = lambda_tgbm
        self.gamma = gamma
        self.max_num_bin = max_num_bin
        self.verbose = verbose
        self.column_sampling_rate = column_sampling_rate
        self.bagging = bagging
        self.n_parallel_trees = n_parallel_trees
        self.learning_rate = learning_rate
        self.objective = objective
        self.num_class = num_class
        self.path = path
        self.out_model_name = out_model_name
        self.in_model_name =  in_model_name
        self.tree_method = tree_method

    #def label_validate(self, y):
        #return column_or_1d(y, warn=True).astype(np.float64)

    def fit(self, X, y):
        sparse = sp.isspmatrix(X)
        self._sparse = sparse
        X, y = check_X_y(X, y, dtype=np.float64, order='C', accept_sparse='csr')
        #y = self.label_validate(y)

        #solver_type = SVM_TYPE.index(self._impl)


        fit = self._sparse_fit
        if self._sparse == False:
            print("dense matrix not supported yet")
            exit(-1)
        fit(X, y)
        if self._train_succeed[0] == -1:
            print ("Training failed!")
            return

        return self

    def _sparse_fit(self, X, y):
        X.data = np.asarray(X.data, dtype=np.float64, order='C')
        X.sort_indices()

        data = (c_float * X.data.size)()
        data[:] = X.data
        indices = (c_int * X.indices.size)()
        indices[:] = X.indices
        indptr = (c_int * X.indptr.size)()
        indptr[:] = X.indptr
        label = (c_float * y.size)()
        label[:] = y

        self._train_succeed = (c_int * 1)()
        thundergbm.sparse_train_scikit(X.shape[0], data, indptr, indices, label, self.depth, self.n_trees,
            self.n_device, c_float(self.min_child_weight), c_float(self.lambda_tgbm), c_float(self.gamma),
            self.max_num_bin, self.verbose, c_float(self.column_sampling_rate), self.bagging,
            self.n_parallel_trees, c_float(self.learning_rate), self.objective.encode('utf-8'),
            self.num_class, self.path.encode('utf-8'), self.out_model_name.encode('utf-8'),
            self.in_model_name.encode('utf-8'), self.tree_method.encode('utf-8'), self._train_succeed)

    def predict(self, X, y = None):
        X.data = np.asarray(X.data, dtype=np.float64, order='C')
        X.sort_indices()
        data = (c_float * X.data.size)()
        data[:] = X.data
        indices = (c_int * X.indices.size)()
        indices[:] = X.indices
        indptr = (c_int * X.indptr.size)()
        indptr[:] = X.indptr
        label = (c_float * y.size)()
        label[:] = y

        thundergbm.sparse_predict_scikit(X.shape[0], data, indptr, indices, label,
                                         self.in_model_name.encode('utf-8'))