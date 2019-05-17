#include <torch/extension.h>

#include <iostream>
#include <cuda.h>
#include <cuda_runtime.h>
#include <driver_functions.h>
#include <map>

template<typename scalar_t, size_t dim>
using Packed = torch::PackedTensorAccessor<scalar_t, dim, torch::RestrictPtrTraits, size_t>;

template<typename scalar_t>
using solver_t = std::function<void (const Packed<scalar_t, 2>, Packed<scalar_t, 1>, const Packed<scalar_t>, scalar_t, int, size_t)>;

template<typename scalar_t>
using method_t = std::function<scalar_t (const scalar_t, scalar_t, const scalar_t, const float)>;

//typedef scalar_t (*method_t)(const scalar_t, scalar_t, const scalar_t, const scalar_t);

template <typename scalar_t>
__device__ __forceinline__ scalar_t
euler_method(const scalar_t F_in, scalar_t x0_in, const scalar_t g_in, const float dt) {
	return (F_in * g_in) * dt;
}

template <typename scalar_t>
__device__ __forceinline__ scalar_t
rk4_method(const scalar_t F_in, scalar_t x0_in, const scalar_t g_in, const float dt) {
	auto f1 = (F_in * g_in)*dt;

	auto c2 = dt * f1 / 2.0;
        auto f2 = (F_in * (g_in + c2)) * (dt / 2.0);

	auto c3 = dt * f2 / 2.0;
        auto f3 = (F_in * (g_in + c3)) * (dt / 2.0);

	auto c4 = dt * f3;
	auto f4 = (F_in * (g_in + c4)) * dt;

	return (f1 + 2.0 * f2 + 2.0 * f3 + f4) / 6.0;
}


template <typename scalar_t>
__global__ void
general_solver(method_t<scalar_t> method, const Packed<scalar_t, 2> F_a, Packed<scalar_t, 1> x0_a, const Packed<scalar_t, 1> g_a, const float dt, int steps, size_t x0_size) {
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    if(tid < x0_size){
        auto x0_in = x0_a[tid];
	auto g_in = g_a[tid];
        auto F_in = F_a[tid][tid];

   	for(int i = 0; i < steps; i++) {
		x0_in = x0_in + method(F_in, x0_in, g_in, dt);
	}

        x0_a[tid] = x0_in;
    }
}

template <typename scalar_t>
__global__ void
compact_diagonal_solver(method_t<scalar_t> method, const Packed<scalar_t, 2> F_a, Packed<scalar_t, 1> x0_a, const Packed<scalar_t, 1> g_a, const float dt, int steps, size_t x0_size) {
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    if(tid < x0_size){
        auto x0_in = x0_a[tid];
	auto g_in = g_a[tid];
	auto F_in = F_a[0][0];

   	for(int i = 0; i < steps; i++) {
		x0_in = x0_in + method(F_in, x0_in, g_in, dt);
	}

        x0_a[tid] = x0_in;
    }
}

template <typename scalar_t>
__global__ void
compact_skew_symmetric_solver(method_t<scalar_t> method, const Packed<scalar_t, 2> F_a, Packed<scalar_t, 1> x0_a, const Packed<scalar_t, 1> g_a, const float dt, int steps, size_t x0_size) {
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    if(tid < x0_size/2) {
	auto g_in_1 = g_a[tid];
	auto g_in_2 = g_a[tid + x0_size/2];

        auto x0_in_1 = x0_a[tid];
        auto x0_in_2 = x0_a[tid + x0_size/2];

	auto UL_v = F_a[0][0];
	auto UR_v = F_a[0][1];
	auto LL_v = F_a[1][0];
	auto LR_v = F_a[1][1];

   	for(int i = 0; i < steps; i++) {
		x0_in_1 = x0_in_1 + method(UL_v, x0_in_1, g_in_1, dt)
				  + method(UR_v, x0_in_2, g_in_2, dt);
		x0_in_2 = x0_in_1 + method(LL_v, x0_in_1, g_in_1, dt)
				  + method(LR_v, x0_in_2, g_in_2, dt);
	}

        x0_a[tid] = x0_in_1;
	x0_a[tid + x0_size/2] = x0_in_2;
    }
}

// Declare static pointers to device functions
__device__ method_t<scalar_t> p_euler_method = euler_method;
__device__ method_t<scalar_t> p_rk4_method = rk4_method;

template <typename scalar_t>
torch::Tensor solve_cuda(torch::Tensor F, torch::Tensor x0, torch::Tensor g, float dt, int steps, std::string name){

    std::map<std::string, method_t<scalar_t>> h_methods;
    method_t<scalar_t> h_euler_method;
    method_t<scalar_t> h_rk4_method; 

    // Copy device function pointers to host side
    cudaMemcpyFromSymbol(&h_euler_method, p_euler_method, sizeof(method_t<scalar_t>));
    cudaMemcpyFromSymbol(&h_rk4_method, p_rk4_method, sizeof(method_t<scalar_t>));

    h_methods["Euler"] = h_euler_method;
    h_methods["RK4"] = h_rk4_method;

    method_t<scalar_t> d_chosen_method = h_methods[name];

    auto F_a = F.packed_accessor<scalar_t, 2, torch::RestrictPtrTraits, size_t>();
    auto x0_a = x0.packed_accessor<scalar_t, 1, torch::RestrictPtrTraits, size_t>();
    auto g_a = g.packed_accessor<scalar_t, 1, torch::RestrictPtrTraits, size_t>();

    auto F_size = torch::size(F, 0);
    auto x0_size = torch::size(x0, 0);

    const int threadsPerBlock = 512; 
    const int blocks = (x0_size + threadsPerBlock - 1) / threadsPerBlock;

    switch(F_size) {
	case 1:
		AT_DISPATCH_FLOATING_TYPES(x0.type(), "solver_cuda", ([&] {
			compact_diagonal_solver<scalar_t><<<blocks, threadsPerBlock>>>(d_chosen_method, F_a, x0_a, g_a, dt, steps, x0_size);
		}));
		break;
	case 2:
		AT_DISPATCH_FLOATING_TYPES(x0.type(), "solver_cuda", ([&] {
			compact_skew_symmetric_solver<scalar_t><<<blocks, threadsPerBlock>>>(d_chosen_method, F_a, x0_a, g_a, dt, steps, x0_size);
		}));
		break;
	default:
		AT_DISPATCH_FLOATING_TYPES(x0.type(), "solver_cuda", ([&] {
			general_solver<scalar_t><<<blocks, threadsPerBlock>>>(
				d_chosen_method, F_a, x0_a, g_a, dt, steps, x0_size);
		}));
		break;
    }
    
    return x0;
}

