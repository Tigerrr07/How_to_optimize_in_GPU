#include <bits/stdc++.h>
#include <cuda.h>
#include "device_launch_parameters.h"
#include <time.h>
#include <sys/time.h>
#include <cuda_runtime_api.h> 
#include <cusparse.h> 

using namespace std;

#define checkCudaErrors(func)				\
{									\
    cudaError_t e = (func);			\
    if(e != cudaSuccess)						                \
        printf ("%s %d CUDA: %s\n", __FILE__,  __LINE__, cudaGetErrorString(e));		\
}

#define CHECK_CUDA(func)                                                       \
{                                                                              \
    cudaError_t status = (func);                                               \
    if (status != cudaSuccess) {                                               \
        printf("CUDA API failed at line %d with error: %s (%d)\n",             \
               __LINE__, cudaGetErrorString(status), status);                  \
        return EXIT_FAILURE;                                                   \
    }                                                                          \
}

#define CHECK_CUSPARSE(func)                                                   \
{                                                                              \
    cusparseStatus_t status = (func);                                          \
    if (status != CUSPARSE_STATUS_SUCCESS) {                                   \
        printf("CUSPARSE API failed at line %d with error: %s (%d)\n",         \
               __LINE__, cusparseGetErrorString(status), status);              \
        return EXIT_FAILURE;                                                   \
    }                                                                          \
}

void add(int a, int b, float c,
    int *h, int *e, int *ne, float *w, int &idx)
{
    e[idx] = b, w[idx] = c, ne[idx] = h[a], h[a] = idx++;
}

void readVerEdges(int &n, int &t, int &m, std::string &file)
{
    std::ifstream input;
    input.open("matrix/" + file + ".mtx");

    while (input.peek() == '%')
        input.ignore(2048, '\n');

    input >> n >> t >> m;

    input.close();
}

void readMtxFile(int n, int m,
            int *row_offset, int *col_index, float *val,
            std::string &file)
{
    ifstream input;
    input.open("matrix/" + file + ".mtx");

    while (input.peek() == '%')
        input.ignore(2048, '\n');

    int t;
    input >> n >> t >> m;
    int *h = (int *)malloc((n + 10) * sizeof(int));
    memset(h, -1, sizeof(int) * (n + 10));
    int *e = (int *)malloc((m + 10) * sizeof(int));
    int *ne = (int *)malloc((m + 10) * sizeof(int));
    float *w = (float *)malloc((m + 10) * sizeof(float));
    int idx = 0;

    int a, b;
    double c;
    srand((int)time(0));
    while (input >> a >> b)
    {
        a--;
        b--;
        c = a%13;
        float tc = static_cast<float>(c);
        add(a, b, tc, h, e, ne, w, idx);
    }

    row_offset[0] = 0;
    int nnz_num = 0;

    for (int i = 0; i < n; i++)
    {
        int count = 0;
        for (int j = h[i]; j != -1; j = ne[j])
        {
            count++;
            int nextNode = e[j];
            float nextWeight = w[j];
            col_index[nnz_num] = nextNode;
            val[nnz_num] = nextWeight;
            nnz_num++;
        }
        row_offset[i + 1] = row_offset[i] + count;
    }

    input.close();
    free(h);
    free(e);
    free(ne);
    free(w);
}

// csr_spmv kernel extracted from the CUSP library v0.4.0
// VECTORS_PER_BLOCK: 每个block负责多少行的计算
// THREADS_PER_VECTOR: 一行需要多少个thread参与计算
template <typename IndexType, typename ValueType, unsigned int VECTORS_PER_BLOCK, unsigned int THREADS_PER_VECTOR>
__global__ void spmv_csr_vector_kernel(const IndexType num_rows,
                       const IndexType * Ap,
                       const IndexType * Aj,
                       const ValueType * Ax,
                       const ValueType * x,
                       ValueType * y)
{
    __shared__ volatile ValueType sdata[VECTORS_PER_BLOCK * THREADS_PER_VECTOR + THREADS_PER_VECTOR / 2];  // padded to avoid reduction conditionals
    __shared__ volatile IndexType ptrs[VECTORS_PER_BLOCK][2];

    // 一个block需要多少个thread参与计算
    const IndexType THREADS_PER_BLOCK = VECTORS_PER_BLOCK * THREADS_PER_VECTOR;

    const IndexType thread_id   = THREADS_PER_BLOCK * blockIdx.x + threadIdx.x;    // global thread index
    // thread_lane 代表是该行的第几个元素
    const IndexType thread_lane = threadIdx.x & (THREADS_PER_VECTOR - 1);          // thread index within the vector
    // vector_id代表当前线程处理第几行的元素
    const IndexType vector_id   = thread_id   /  THREADS_PER_VECTOR;               // global vector index
    // vector_lane 代表是当前block中的第几行
    const IndexType vector_lane = threadIdx.x /  THREADS_PER_VECTOR;               // vector index within the block
    const IndexType num_vectors = VECTORS_PER_BLOCK * gridDim.x;                   // total number of active vectors

    for(IndexType row = vector_id; row < num_rows; row += num_vectors)
    {
        // use two threads to fetch Ap[row] and Ap[row+1]
        // this is considerably faster than the straightforward version
        if(thread_lane < 2)
            ptrs[vector_lane][thread_lane] = Ap[row + thread_lane];

        const IndexType row_start = ptrs[vector_lane][0];                   //same as: row_start = Ap[row];
        const IndexType row_end   = ptrs[vector_lane][1];                   //same as: row_end   = Ap[row+1];

        // initialize local sum
        ValueType sum = 0;

        if (THREADS_PER_VECTOR == 32 && row_end - row_start > 32)
        {
            // ensure aligned memory access to Aj and Ax

            IndexType jj = row_start - (row_start & (THREADS_PER_VECTOR - 1)) + thread_lane;

            // accumulate local sums
            if(jj >= row_start && jj < row_end)
                sum += Ax[jj] * x[ Aj[jj] ];

            // accumulate local sums
            for(jj += THREADS_PER_VECTOR; jj < row_end; jj += THREADS_PER_VECTOR)
                sum += Ax[jj] * x[ Aj[jj] ];
        }
        else
        {
            // accumulate local sums
            for(IndexType jj = row_start + thread_lane; jj < row_end; jj += THREADS_PER_VECTOR)
                sum += Ax[jj] * x[ Aj[jj] ];
        }

        // store local sum in shared memory
        sdata[threadIdx.x] = sum;
        
        // reduce local sums to row sum
        if (THREADS_PER_VECTOR > 16) sdata[threadIdx.x] = sum = sum + sdata[threadIdx.x + 16];
        if (THREADS_PER_VECTOR >  8) sdata[threadIdx.x] = sum = sum + sdata[threadIdx.x +  8];
        if (THREADS_PER_VECTOR >  4) sdata[threadIdx.x] = sum = sum + sdata[threadIdx.x +  4];
        if (THREADS_PER_VECTOR >  2) sdata[threadIdx.x] = sum = sum + sdata[threadIdx.x +  2];
        if (THREADS_PER_VECTOR >  1) sdata[threadIdx.x] = sum = sum + sdata[threadIdx.x +  1];

        // first thread writes the result
        if (thread_lane == 0)
            y[row] = sdata[threadIdx.x];
    }
}

template <unsigned int WarpSize>
__device__ __forceinline__ float warpReduceSum(float sum) {
    if (WarpSize >= 32)sum += __shfl_down_sync(0xffffffff, sum, 16); // 0-16, 1-17, 2-18, etc.
    if (WarpSize >= 16)sum += __shfl_down_sync(0xffffffff, sum, 8);// 0-8, 1-9, 2-10, etc.
    if (WarpSize >= 8)sum += __shfl_down_sync(0xffffffff, sum, 4);// 0-4, 1-5, 2-6, etc.
    if (WarpSize >= 4)sum += __shfl_down_sync(0xffffffff, sum, 2);// 0-2, 1-3, 4-6, 5-7, etc.
    if (WarpSize >= 2)sum += __shfl_down_sync(0xffffffff, sum, 1);// 0-1, 2-3, 4-5, etc.
    return sum;
}

template <typename IndexType, typename ValueType, unsigned int VECTORS_PER_BLOCK, unsigned int THREADS_PER_VECTOR>
__global__ void My_spmv_csr_kernel(const IndexType row_num,
                       const IndexType * A_row_offset,
                       const IndexType * A_col_index,
                       const ValueType * A_value,
                       const ValueType * x,
                       ValueType * y)
{
    const IndexType THREADS_PER_BLOCK = VECTORS_PER_BLOCK * THREADS_PER_VECTOR;
    const IndexType thread_id   = THREADS_PER_BLOCK * blockIdx.x + threadIdx.x;    // global thread index
    const IndexType thread_lane = threadIdx.x & (THREADS_PER_VECTOR - 1);          // thread index within the vector
    const IndexType row_id   = thread_id   /  THREADS_PER_VECTOR;               // global vector index

    if(row_id < row_num){
        const IndexType row_start = A_row_offset[row_id];                  
        const IndexType row_end   = A_row_offset[row_id+1];

        // initialize local sum
        ValueType sum = 0;

        // accumulate local sums
        for(IndexType jj = row_start + thread_lane; jj < row_end; jj += THREADS_PER_VECTOR)
            sum += A_value[jj] * x[ A_col_index[jj] ];

        sum = warpReduceSum<THREADS_PER_VECTOR>(sum);
        if (thread_lane == 0){
            y[row_id] = sum;
        }   
    }
}

template<typename T>
void vec_print(vector<T> array){
    for(auto x: array){
        cout<<x<<" ";
    }
    cout<<std::endl;
}

template <typename IndexType, typename ValueType>
void spmv_cpu_kernel(vector<IndexType> &row_offset,
                vector<IndexType> &col_index,
                vector<ValueType> &value,
                vector<ValueType> &x,
                vector<ValueType> &y,
                IndexType row_num)
{
    for(int i=0; i<row_num; i++){
        ValueType res = 0;
        IndexType num = row_offset[i+1] - row_offset[i];
        for(int j=0; j<num; j++){
            IndexType index = row_offset[i] + j;
            res += value[index]*x[col_index[index]];
        }
        y[i] = res;
    }
}

int main(int argc, char **argv)
{
    if (argc != 3) {
        printf("usage: ./spmv -f [matrix]\n");
        exit(0);
    }
    string file;
    for (int i = 1; i < argc; i++)
    {
        if (strcmp(argv[i], "-f") == 0)
        {
            file = argv[i + 1];
        }
    }

    // read mtx file and convert to csr
    // Now, we just support unsymmetric 0-1 matrix
    int row_num;
    int col_num;
    int nnz_num;
    readVerEdges(row_num, col_num, nnz_num, file);
    vector<int> row_offset(row_num + 1);
    vector<int> col_index(nnz_num);
    vector<float> value(nnz_num);
    vector<float> x(col_num,1.0);
    vector<float> y(row_num);
    vector<float> y_res(row_num);
    vector<float> y_cusparse_res(row_num);
    int iter = 2000;
    readMtxFile(row_num, nnz_num, row_offset.data(), col_index.data(), value.data(), file);

    // check input
    // std::cout<<" The row_offset is: "<<std::endl;
    // vec_print<int>(row_offset);
    // std::cout<<" The col_index is: "<<std::endl;
    // vec_print<int>(col_index);
    // std::cout<<" The value is: "<<std::endl;
    // vec_print<float>(value);

    // allocate memory in GPU device
    int* d_A_row_offset;
    int* d_A_col_index;
    float* d_A_value;
    float* d_x;
    float* d_y;
    float* d_y_cusparse;

    checkCudaErrors(cudaMalloc(&d_A_row_offset, (row_num + 1)*sizeof(int)));
    checkCudaErrors(cudaMalloc(&d_A_col_index, nnz_num*sizeof(int)));
    checkCudaErrors(cudaMalloc(&d_A_value, nnz_num*sizeof(float)));
    checkCudaErrors(cudaMalloc(&d_x, col_num*sizeof(float)));
    checkCudaErrors(cudaMalloc(&d_y, row_num*sizeof(float)));
    checkCudaErrors(cudaMalloc(&d_y_cusparse, row_num*sizeof(float)));
    checkCudaErrors(cudaMemcpy( d_A_row_offset, row_offset.data(), (row_num + 1)*sizeof(int), cudaMemcpyHostToDevice));
    checkCudaErrors(cudaMemcpy( d_A_col_index, col_index.data(), nnz_num*sizeof(int), cudaMemcpyHostToDevice));
    checkCudaErrors(cudaMemcpy( d_A_value, value.data(), nnz_num*sizeof(float), cudaMemcpyHostToDevice));
    checkCudaErrors(cudaMemcpy( d_x, x.data(), col_num*sizeof(float), cudaMemcpyHostToDevice));
    
    // spmv
    // 32 thread for a row
    const int THREADS_PER_VECTOR = 32;
    const unsigned int VECTORS_PER_BLOCK  = 128 / THREADS_PER_VECTOR;
    const unsigned int THREADS_PER_BLOCK  = VECTORS_PER_BLOCK * THREADS_PER_VECTOR;

    //const unsigned int MAX_BLOCKS = MAX_THREADS / THREADS_PER_BLOCK;
    const unsigned int MAX_BLOCKS = 16 * 1024;
    const unsigned int NUM_BLOCKS = std::min(MAX_BLOCKS, static_cast<unsigned int>((row_num + (VECTORS_PER_BLOCK - 1)) / VECTORS_PER_BLOCK));
    for(int i=0; i<iter; i++){
        spmv_csr_vector_kernel<int, float, VECTORS_PER_BLOCK, THREADS_PER_VECTOR> <<<NUM_BLOCKS, THREADS_PER_BLOCK>>> 
            (row_num, d_A_row_offset, d_A_col_index, d_A_value, d_x, d_y);
    }
    checkCudaErrors(cudaMemcpy(y.data(), d_y, row_num*sizeof(float), cudaMemcpyDeviceToHost));

    // cusparse spmv
    //--------------------------------------------------------------------------
    // CUSPARSE APIs
    float     alpha           = 1.0f;
    float     beta            = 0.0f;

    cusparseHandle_t     handle = NULL;
    cusparseSpMatDescr_t matA;
    cusparseDnVecDescr_t vecX, vecY;
    void*                dBuffer    = NULL;
    size_t               bufferSize = 0;
    CHECK_CUSPARSE( cusparseCreate(&handle) )
    // Create sparse matrix A in CSR format
    CHECK_CUSPARSE( cusparseCreateCsr(&matA, row_num, col_num, nnz_num,
                                      d_A_row_offset, d_A_col_index, d_A_value,
                                      CUSPARSE_INDEX_32I, CUSPARSE_INDEX_32I,
                                      CUSPARSE_INDEX_BASE_ZERO, CUDA_R_32F) )
    // Create dense vector X
    CHECK_CUSPARSE( cusparseCreateDnVec(&vecX, col_num, d_x, CUDA_R_32F) )
    // Create dense vector y
    CHECK_CUSPARSE( cusparseCreateDnVec(&vecY, row_num, d_y_cusparse, CUDA_R_32F) )
    // allocate an external buffer if needed
    CHECK_CUSPARSE( cusparseSpMV_bufferSize(
                                 handle, CUSPARSE_OPERATION_NON_TRANSPOSE,
                                 &alpha, matA, vecX, &beta, vecY, CUDA_R_32F,
                                 CUSPARSE_MV_ALG_DEFAULT, &bufferSize) )
    CHECK_CUDA( cudaMalloc(&dBuffer, bufferSize) )

    // execute SpMV
    for(int i=0; i<iter; i++){
        CHECK_CUSPARSE( cusparseSpMV(handle, CUSPARSE_OPERATION_NON_TRANSPOSE,
                                    &alpha, matA, vecX, &beta, vecY, CUDA_R_32F,
                                    CUSPARSE_MV_ALG_DEFAULT, dBuffer) )
    }

    // destroy matrix/vector descriptors
    CHECK_CUSPARSE( cusparseDestroySpMat(matA) )
    CHECK_CUSPARSE( cusparseDestroyDnVec(vecX) )
    CHECK_CUSPARSE( cusparseDestroyDnVec(vecY) )
    CHECK_CUSPARSE( cusparseDestroy(handle) )
    //--------------------------------------------------------------------------
    // device result check
    CHECK_CUDA( cudaMemcpy(y_cusparse_res.data(), d_y_cusparse, row_num * sizeof(float),
                           cudaMemcpyDeviceToHost) )

    bool check_result = true;
    for(int i=0; i<row_num; i++){
        if(fabs(y[i]-y_cusparse_res[i])>1e-6){
            std::cout<<"The result is error!"<<std::endl;
            check_result = false;
            break;
        }
    }
    if(check_result){
        std::cout<<"The result is right!"<<std::endl;
    }

    // Free Memory
    cudaFree(d_A_row_offset);
    cudaFree(d_A_col_index);
    cudaFree(d_A_value);
    cudaFree(d_x);
    cudaFree(d_y);

    return 0;
}
