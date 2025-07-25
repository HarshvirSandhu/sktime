"""Time series DBSCAN, wrapping sklearn DBSCAN."""

__author__ = ["fkiraly"]

from sklearn.cluster import DBSCAN

from sktime.clustering.base import BaseClusterer
from sktime.datatypes import update_data
from sktime.dists_kernels.base import BasePairwiseTransformerPanel
from sktime.utils.warnings import warn


class TimeSeriesDBSCAN(BaseClusterer):
    """DBSCAN for time series distances.

    Interface to sklearn DBSCAN with sktime time series distances.

    Parameters
    ----------
    distance : str, or callable, default='euclidean'
        The metric to use when calculating distance between instances in a
        feature array. If metric is a string or callable, it must be one of
        the options allowed by :func:`sklearn.metrics.pairwise_distances` for
        its metric parameter.
        If metric is "precomputed", X is assumed to be a distance matrix and
        must be square. X may be a :term:`Glossary <sparse graph>`, in which
        case only "nonzero" elements may be considered neighbors for DBSCAN.
    eps : float, default=0.5
        The maximum distance between two samples for one to be considered
        as in the neighborhood of the other. This is not a maximum bound
        on the distances of points within a cluster. This is the most
        important DBSCAN parameter to choose appropriately for your data set
        and distance function.
    min_samples : int, default=5
        The number of samples (or total weight) in a neighborhood for a point
        to be considered as a core point. This includes the point itself.
    algorithm : {'auto', 'ball_tree', 'kd_tree', 'brute'}, default='auto'
        The algorithm to be used by the NearestNeighbors module
        to compute pointwise distances and find nearest neighbors.
        See NearestNeighbors module documentation for details.
    leaf_size : int, default=30
        Leaf size passed to BallTree or cKDTree. This can affect the speed
        of the construction and query, as well as the memory required
        to store the tree. The optimal value depends
        on the nature of the problem.
    n_jobs : int, default=None
        The number of parallel jobs to run.
        ``None`` means 1 unless in a :obj:`joblib.parallel_backend` context.
        ``-1`` means using all processors. See :term:`Glossary <n_jobs>`
        for more details.

    Attributes
    ----------
    core_sample_indices_ : ndarray of shape (n_core_samples,)
        Indices of core samples.
    components_ : ndarray of shape (n_core_samples, n_features)
        Copy of each core sample found by training.
    labels_ : ndarray of shape (n_samples)
        Cluster labels for each point in the dataset given to fit().
        Noisy samples are given the label -1.
    """

    _tags = {
        # packaging info
        # --------------
        "authors": "fkiraly",
        # estimator type
        # --------------
        "capability:multivariate": True,
        "capability:unequal_length": True,
        "capability:missing_values": True,
        "X_inner_mtype": ["pd-multiindex", "numpy3D"],
        # required by the update_data utility
        # otherwise, we could pass through to the distance directly
        "capability:out_of_sample": False,
        "capability:predict": True,
        "capability:predict_proba": False,
        # CI and test flags
        # -----------------
        "tests:core": True,  # should tests be triggered by framework changes?
    }

    DELEGATED_PARAMS = ["eps", "min_samples", "algorithm", "leaf_size", "n_jobs"]
    DELEGATED_FITTED_PARAMS = ["core_sample_indices_", "components_ ", "labels_"]

    def __init__(
        self,
        distance,
        eps=0.5,
        min_samples=5,
        algorithm="auto",
        leaf_size=30,
        n_jobs=None,
    ):
        self.distance = distance
        self.eps = eps
        self.min_samples = min_samples
        self.algorithm = algorithm
        self.leaf_size = leaf_size
        self.n_jobs = n_jobs

        super().__init__()

        if isinstance(distance, BasePairwiseTransformerPanel):
            tags_to_clone = [
                "capability:multivariate",
                "capability:unequal_length",
                "capability:missing_values",
            ]
            self.clone_tags(distance, tags_to_clone)

        # numba distance in sktime (indexed by string)
        # cannot support unequal length data, and require numpy3D input
        if isinstance(distance, str):
            tags_to_set = {
                "X_inner_mtype": "numpy3D",
                "capability:unequal_length": False,
            }
            self.set_tags(**tags_to_set)

        self.dbscan_ = None

    def _fit(self, X, y=None):
        """Fit time series clusterer to training data.

        Parameters
        ----------
        X : panel of time series, any sklearn Panel mtype
            Time series to fit clusters to
        y: ignored, exists for API consistency reasons

        Returns
        -------
        self:
            Fitted estimator.
        """
        self._X = X

        distance = self.distance
        distmat = distance(X)

        deleg_param_dict = {key: getattr(self, key) for key in self.DELEGATED_PARAMS}

        self.dbscan_ = DBSCAN(metric="precomputed", **deleg_param_dict)
        self.dbscan_.fit(X=distmat)

        for key in self.DELEGATED_FITTED_PARAMS:
            if hasattr(self.dbscan_, key):
                setattr(self, key, getattr(self.dbscan_, key))

        return self

    def _predict(self, X, y=None):
        """Predict the closest cluster each sample in X belongs to.

        Parameters
        ----------
        X : panel of time series, any sklearn Panel mtype
            Time series instances to predict cluster indexes for
        y: ignored, exists for API consistency reasons

        Returns
        -------
        np.ndarray (1d array of shape (n_instances,))
            Index of the cluster each time series in X belongs to
        """
        # if X is the same as seen in _fit, simply return the labels
        if X is self._X:
            return self.labels_
        else:
            all_X = update_data(X=self._X, X_new=X)
            warn(
                "sklearn and sktime DBSCAN estimators do not support different X "
                "in fit and predict, but a new X was passed in predict. "
                "Therefore, a clone of TimeSeriesDBSCAN will be fit, and results "
                "returned, without updating the state of the fitted estimator.",
                obj=self,
            )
            return self.clone().fit(all_X).labels_

    @classmethod
    def get_test_params(cls, parameter_set="default"):
        """Return testing parameter settings for the estimator.

        Parameters
        ----------
        parameter_set : str, default="default"
            Name of the set of test parameters to return, for use in tests. If no
            special parameters are defined for a value, will return `"default"` set.


        Returns
        -------
        params : dict or list of dict, default = {}
            Parameters to create testing instances of the class
            Each dict are parameters to construct an "interesting" test instance, i.e.,
            `MyClass(**params)` or `MyClass(**params[i])` creates a valid test instance.
            `create_test_instance` uses the first (or only) dictionary in `params`
        """
        from sktime.dists_kernels import AggrDist, DtwDist, EditDist

        # distance capable of unequal length
        # also has no soft dependencies
        dist = AggrDist.create_test_instance()
        params1 = {"distance": dist}

        params2 = {"distance": DtwDist()}
        params3 = {"distance": EditDist()}

        return [params1, params2, params3]
