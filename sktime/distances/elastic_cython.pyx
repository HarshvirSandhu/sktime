# cython: language_level=3

import numpy as np
from scipy.spatial.distance import cdist
cimport numpy as np
cimport cython
np.import_array()

from libc.float cimport DBL_MAX
from libc.math cimport exp, sqrt, fabs

cdef inline double min_c(double a, double b): return a if a <= b else b
cdef inline int max_c_int(int a, int b): return a if a >= b else b
cdef inline int min_c_int(int a, int b): return a if a <= b else b

# it takes as argument two time series with shape (l,m) where l is the length
# of the time series and m is the number of dimensions
# for multivariate time series
# even if we have univariate time series, we should have a shape equal to (l,1)
# the w argument corresponds to the length of the warping window in percentage of
# the smallest length of the time series min(x,y) - if negative then no warping window
# this function assumes that x is shorter than y
@cython.boundscheck(False)  # Deactivate bounds checking
@cython.wraparound(False)   # Deactivate negative indexing.
def dtw_distance(np.ndarray[double, ndim=2] x, np.ndarray[double, ndim=2] y , double w = -1):
    # make sure x is shorter than y
    # if not permute
    cdef np.ndarray[double, ndim=2] X = x
    cdef np.ndarray[double, ndim=2] Y = y
    cdef np.ndarray[double, ndim=2] t

    if len(X)>len(Y):
        t = X
        X = Y
        Y = t

    cdef int r,c, im,jm,lx, jstart, jstop, idx_inf_left, ly, band
    cdef Py_ssize_t i, j
    cdef double curr

    lx = len(X)
    ly = len(Y)
    r = lx + 1
    c = ly +1

    if w < 0:
        band = max_c_int(lx,ly)
    else:
        band = int(w*max_c_int(lx,ly))
    cdef np.ndarray[double, ndim=2] D = np.zeros((r,c), dtype=np.float64)

    D[0,1:] = DBL_MAX
    D[1:,0] = DBL_MAX

    D[1:,1:] = np.square(X[:,np.newaxis]-Y).sum(axis=2).astype(np.float64) # inspired by https://stackoverflow.com/a/27948463/9234713


    for i in range(1,r):
        jstart = max_c_int(1 , i-band)
        jstop = min_c_int(c , i+band+1)
        idx_inf_left = i-band-1

        if idx_inf_left >= 0 :
            D[i,idx_inf_left] = DBL_MAX

        for j in range(jstart,jstop):
            im = i-1
            jm = j-1
            D[i,j] = D[i,j] + min_c(min_c(D[im,j],D[i,jm]),D[im,jm])

        if jstop < c:
            D[i][jstop] = DBL_MAX

    return D[lx,ly]


def wdtw_distance(np.ndarray[double, ndim=2] x, np.ndarray[double, ndim=2] y , double g = 0):

    # make sure x is shorter than y
    # if not permute
    cdef np.ndarray[double, ndim=2] X = x
    cdef np.ndarray[double, ndim=2] Y = y
    cdef np.ndarray[double, ndim=2] t

    if len(X)>len(Y):
        t = X
        X = Y
        Y = t

    cdef int r,c, im,jm,lx, jstart, jstop, idx_inf_left, ly, band
    cdef Py_ssize_t i, j
    cdef double curr

    lx = len(X)
    ly = len(Y)
    r = lx + 1
    c = ly +1

    # get weights with cdef helper function
    cdef np.ndarray[double, ndim=1] weight_vector = _wdtw_calc_weights(lx,g)
    cdef np.ndarray[double, ndim=2] D = np.zeros((r,c), dtype=np.float64)

    D[0,1:] = DBL_MAX
    D[1:,0] = DBL_MAX

    D[1:,1:] = np.square(X[:,np.newaxis]-Y).sum(axis=2).astype(np.float64) # inspired by https://stackoverflow.com/a/27948463/9234713

    for row in range(1,r):
        for column in range(1,c):
            D[row,column] *= weight_vector[<int>fabs(row-column)]

    for i in range(1,r):
        jstart = max_c_int(1 , i-ly)
        jstop = min_c_int(c , i+ly+1)
        idx_inf_left = i-ly-1

        if idx_inf_left >= 0 :
            D[i,idx_inf_left] = DBL_MAX

        for j in range(jstart,jstop):
            im = i-1
            jm = j-1
            # D[i,j] = min_c(min_c(D[im,j],D[i,jm]),D[im,jm]) + weight_vector[j-i]*D[i,j]
            D[i,j] = min_c(min_c(D[im,j],D[i,jm]),D[im,jm]) + D[i,j]

        if jstop < c:
            D[i][jstop] = DBL_MAX

    return D[lx,ly]

# note - this implementation is more convenient for use in ensembles, etc., but it is more efficient
# for standalone use to transform the data once, then use DTW on the transformed data
# @cython.boundscheck(False)  # Deactivate bounds checking
# @cython.wraparound(False)   # Deactivate negative indexing.
def ddtw_distance(np.ndarray[double, ndim=2] x, np.ndarray[double, ndim=2] y , double w = -1):
    return dtw_distance(np.diff(x.T).T,np.diff(y.T).T,w)




# note - this implementation is more convenient for use in ensembles, etc., but it is more efficient
# for standalone use to transform the data once, then use WDTW on the transformed data
# @cython.boundscheck(False)  # Deactivate bounds checking
# @cython.wraparound(False)   # Deactivate negative indexing.
def wddtw_distance(np.ndarray[double, ndim=2] x, np.ndarray[double, ndim=2] y , double g = 0):
    return wdtw_distance(np.diff(x.T).T,np.diff(y.T).T,g)


# @cython.boundscheck(False)  # Deactivate bounds checking
# @cython.wraparound(False)   # Deactivate negative indexing.
def msm_distance(np.ndarray[double, ndim=2] x, np.ndarray[double, ndim=2] y, double c = 0, int dim_to_use = 0):

    cdef np.ndarray[double, ndim=2] first = x
    cdef np.ndarray[double, ndim=2] second = y
    cdef np.ndarray[double, ndim=2] temp

    if len(first) > len(second):
        temp = first
        first = second
        second = temp

    cdef Py_ssize_t i, j
    cdef int rows,columns, im, jm, lx, jstart, jstop, idx_inf_left, ly, m, n
    cdef double curr, d1, d2, d3, t

    m = len(first)
    n = len(second)

    cdef np.ndarray[double, ndim=2] cost = np.zeros((m,n),dtype=np.float64)

    # Initialization
    cost[0, 0] = fabs(first[0,dim_to_use] - second[0,dim_to_use])
    for i in range(1,m):
        # cost[i, 0] = cost[i - 1, 0] + _msm_calc_cost(first[i], first[i - 1], second[0], c)
        t = _msm_calc_cost(first[i,dim_to_use], first[i - 1,dim_to_use], second[0,dim_to_use], c)
        cost[i, 0] = cost[i - 1, 0] + t

    for i in range(1, n):
        # cost[0, i] = cost[0, i - 1] + _msm_calc_cost(second[i], first[0], second[i - 1], c)
        t = _msm_calc_cost(second[i,dim_to_use], first[0,dim_to_use], second[i - 1,dim_to_use], c)
        cost[0, i] = cost[0, i - 1] + t

     # Main Loop
    for i in range(1, m):
        for j in range(1, n):
            d1 = cost[i - 1, j - 1] + fabs(first[i,dim_to_use] - second[j,dim_to_use])
            d2 = cost[i - 1, j] + _msm_calc_cost(first[i,dim_to_use], first[i - 1,dim_to_use], second[j,dim_to_use], c)
            d3 = cost[i, j - 1] + _msm_calc_cost(second[j,dim_to_use], first[i,dim_to_use], second[j - 1,dim_to_use], c)
            cost[i, j] = min_c(min_c(d1,d2),d3)

    return cost[m - 1, n - 1];

#
# @cython.boundscheck(False)  # Deactivate bounds checking
# @cython.wraparound(False)   # Deactivate negative indexing.
cdef _msm_calc_cost(double new_point, double x, double y, double c):
    cdef double dist = 0

    if ((x <= new_point) and (new_point <= y)) or ((y <= new_point) and (new_point <= x)):
        return c
    else:
        return c + min_c(fabs(new_point - x), fabs(new_point - y))

# @cython.boundscheck(False)  # Deactivate bounds checking
# @cython.wraparound(False)   # Deactivate negative indexing.
def lcss_distance(np.ndarray[double, ndim=2] x, np.ndarray[double, ndim=2] y, int delta = 3, double epsilon = 1.0, int dim_to_use = 0):

    cdef np.ndarray[double, ndim=2] first = x
    cdef np.ndarray[double, ndim=2] second = y
    cdef np.ndarray[double, ndim=2] temp

    cdef int m, n, max_val
    cdef Py_ssize_t i, j

    if len(first) > len(second):
        temp = first
        first = second
        second = temp

    m = len(first)
    n = len(second)

    cdef np.ndarray[int, ndim=2] lcss = np.zeros([m + 1, n + 1], dtype=int)

    for i in range(m):
        for j in range(i - delta, i + delta + 1):
            if j < 0:
                j = -1
            elif j >= n:
                j = i + delta
            elif second[j, dim_to_use] + epsilon >= first[i, dim_to_use] >= second[j, dim_to_use] - epsilon:
                lcss[i + 1, j + 1] = lcss[i,j] + 1
            elif lcss[i,j + 1] > lcss[i + 1,j]:
                lcss[i + 1,j + 1] = lcss[i,j + 1]
            else:
                lcss[i + 1,j + 1] = lcss[i + 1, j]

    max_val = -1;
    for i in range(1, len(lcss[len(lcss) - 1])):
        if lcss[len(lcss) - 1, i] > max_val:
            max_val = lcss[len(lcss) - 1, i];

    return 1 - (max_val / m)

# @cython.boundscheck(False)  # Deactivate bounds checking
# @cython.wraparound(False)   # Deactivate negative indexing.
def erp_distance(np.ndarray[double, ndim=2] x, np.ndarray[double, ndim=2] y, int band_size = 5, double g = 0.5, int dim_to_use = 0):
    """
    Adapted from:
        This file is part of ELKI:
        Environment for Developing KDD-Applications Supported by Index-Structures

        Copyright (C) 2011
        Ludwig-Maximilians-UniversitÃ¤t MÃ¼nchen
        Lehr- und Forschungseinheit fÃ¼r Datenbanksystemethe
        ELKI Development Team

        This program is free software: you can redistribute it and/or modify
        it under the terms of the GNU Affero General Public License as published by
        the Free Software Foundation, either version 3 of the License, or
        (at your option) any later version.

        This program is distributed in the hope that it will be useful,
        but WITHOUT ANY WARRANTY; without even the implied warranty of
        MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
        GNU Affero General Public License for more details.

        You should have received a copy of the GNU Affero General Public License
        along with this program.  If not, see <http://www.gnu.org/licenses/>.
    """
    cdef np.ndarray[double, ndim=2] first = x
    cdef np.ndarray[double, ndim=2] second = y
    cdef np.ndarray[double, ndim=2] t

    cdef Py_ssize_t i, j
    cdef int m, n, band, l, r
    cdef double val1, val2, diff, d1, d2, d12, dist1, dist2, dist12, cost

    if len(first) > len(second):
        t = first
        first = second
        second = t

    m = len(first)
    n = len(second)

    cdef np.ndarray[double, ndim=1] curr = np.zeros(m)
    cdef np.ndarray[double, ndim=1] prev = np.zeros(m)
    cdef np.ndarray[double, ndim=1] temp = np.zeros(m)

    band = np.ceil(band_size * m)


    for i in range(0, m):
        temp = prev
        prev = curr
        curr = temp
        l = i - (band + 1)

        if l < 0:
            l = 0

        r = i + (band + 1);
        if r > m - 1:
            r = (m - 1)

        for j in range(l, r + 1):
            if fabs(i - j) <= band:

                if i + j != 0:

                    val1 = first[i,dim_to_use]
                    val2 = g
                    diff = (val1 - val2)
                    d1 = sqrt(diff * diff)

                    val1 = g
                    val2 = second[j,dim_to_use]
                    diff = (val1 - val2)
                    d2 = sqrt(diff * diff)

                    val1 = first[i,dim_to_use]
                    val2 = second[j,dim_to_use]
                    diff = (val1 - val2)
                    d12 = sqrt(diff * diff)

                    dist1 = d1 * d1
                    dist2 = d2 * d2
                    dist12 = d12 * d12

                    if i == 0 or (j != 0 and (((prev[j - 1] + dist12) > (curr[j - 1] + dist2)) and ((curr[j - 1] + dist2) < (prev[j] + dist1)))):
                        # del
                        cost = curr[j - 1] + dist2
                    elif (j == 0) or ((i != 0) and (((prev[j - 1] + dist12) > (prev[j] + dist1)) and ((prev[j] + dist1) < (curr[j - 1] + dist2)))):
                        # ins
                        cost = prev[j] + dist1;
                    else:
                        # match
                        cost = prev[j - 1] + dist12
                else:
                    cost = 0
                curr[j] = cost

    return sqrt(curr[m - 1])

# @cython.boundscheck(False)  # Deactivate bounds checking
# @cython.wraparound(False)   # Deactivate negative indexing.
cdef _get_der(np.ndarray[double, ndim=2] x):
    cdef np.ndarray[double, ndim=2] der_x = np.empty((len(x),len(x[0])-1))
    cdef int i
    for i in range(len(x)):
        der_x[i] = np.diff(x[i])
    return der_x

# @cython.boundscheck(False)  # Deactivate bounds checking
# @cython.wraparound(False)   # Deactivate negative indexing.
cdef _wdtw_calc_weights(int len_x, double g):
    cdef np.ndarray[double, ndim=1] weight_vector = np.zeros(len_x)
    cdef int i
    for i in range(len_x):
        # weight_vector[i] = 1/(1+np.exp(-g*(i-len_x/2)))
        weight_vector[i] = 1/(1+exp(-g*(i-len_x/2)))
    return weight_vector
