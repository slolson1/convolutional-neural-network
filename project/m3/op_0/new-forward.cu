#include <cmath>
#include <iostream>
#include "gpu-new-forward.h"

#define TILE_WIDTH 16
#define NUM_STREAMS 20

__global__ void conv_forward_kernel(float *output, const float *input, const float *mask, const int Batch, const int Map_out, const int Channel, const int Height, const int Width, const int K)
{
    /*
    Modify this function to implement the forward pass described in Chapter 16.
    We have added an additional dimension to the tensors to support an entire mini-batch
    The goal here is to be correct AND fast.

    Function paramter definitions:
    output - output
    input - input
    mask - convolution kernel
    Batch - batch_size (number of images in x)
    Map_out - number of output feature maps
    Channel - number of input feature maps
    Height - input height dimension
    Width - input width dimension
    K - kernel height and width (K x K)
    */

    const int Height_out = Height - K + 1;
    const int Width_out = Width - K + 1;
    const int W_grid = (Width_out + TILE_WIDTH - 1) / TILE_WIDTH;
    //(void)Height_out; // silence declared but never referenced warning. remove this line when you start working
    //(void)Width_out; // silence declared but never referenced warning. remove this line when you start working

    // We have some nice #defs for you below to simplify indexing. Feel free to use them, or create your own.
    // An example use of these macros:
    // float a = in_4d(0,0,0,0)
    // out_4d(0,0,0,0) = a

    #define out_4d(i3, i2, i1, i0) output[(i3) * (Map_out * Height_out * Width_out) + (i2) * (Height_out * Width_out) + (i1) * (Width_out) + i0]
    #define in_4d(i3, i2, i1, i0) input[(i3) * (Channel * Height * Width) + (i2) * (Height * Width) + (i1) * (Width) + i0]
    #define mask_4d(i3, i2, i1, i0) mask[(i3) * (Channel * K * K) + (i2) * (K * K) + (i1) * (K) + i0]

    // Insert your GPU convolution kernel code here
    int m = blockIdx.x;
    int b = blockIdx.z;
    int h = (blockIdx.y / W_grid) * TILE_WIDTH + threadIdx.y;
    int w = (blockIdx.y % W_grid) * TILE_WIDTH + threadIdx.x;
    float acc = 0.0f;
    if ((h < Height_out) && (w < Width_out)) {
        for (int c = 0; c < Channel; c++)
            for (int p = 0; p < K; p++)
                for (int q = 0; q < K; q++)
                    acc += in_4d(b, c, h+p, w+q) * mask_4d(m, c, p, q);
    
        out_4d(b, m, h, w) = acc;
    }

    #undef out_4d
    #undef in_4d
    #undef mask_4d
}

	
__host__ void GPUInterface::conv_forward_gpu_prolog(const float *host_output, const float *host_input, const float *host_mask, float **device_output_ptr, float **device_input_ptr, float **device_mask_ptr, const int Batch, const int Map_out, const int Channel, const int Height, const int Width, const int K)
{
    // Allocate memory and copy over the relevant data structures to the GPU
    const int Height_out = Height - K + 1;
    const int Width_out = Width - K + 1;
    const int W_grid = (Width_out + TILE_WIDTH - 1) / TILE_WIDTH;
    const int H_grid = (Height_out + TILE_WIDTH - 1) / TILE_WIDTH;
    const int Y = H_grid * W_grid;
    const int input_stream_size = (Batch * Channel * Height * Width) / NUM_STREAMS;
    const int output_stream_size = (Batch * Map_out * Height_out * Width_out) / NUM_STREAMS;
    float *pinned_input, *pinned_output;

    cudaHostAlloc((void **) &pinned_input, Batch * Channel * Height * Width * sizeof(float), cudaHostAllocDefault);
    cudaHostAlloc((void **) &pinned_output, Batch * Map_out * Height_out * Width_out * sizeof(float), cudaHostAllocDefault);
    cudaMemcpy(pinned_input, host_input, Batch * Channel * Height * Width * sizeof(float), cudaMemcpyHostToHost);

    cudaMalloc((void**) device_input_ptr, Batch * Channel * Height * Width * sizeof(float));
    cudaMalloc((void**) device_mask_ptr, Map_out * Channel * K * K * sizeof(float));
    cudaMalloc((void**) device_output_ptr, Batch * Map_out * Height_out * Width_out * sizeof(float));
    cudaMemcpy(*device_mask_ptr, host_mask, Map_out * Channel * K * K * sizeof(float), cudaMemcpyHostToDevice);

    dim3 DimGrid(Map_out, Y, ceil(Batch/NUM_STREAMS));
    dim3 DimBlock(TILE_WIDTH, TILE_WIDTH, 1);

    cudaStream_t stream[NUM_STREAMS];
    for (int i = 0; i < NUM_STREAMS; i++) cudaStreamCreate(&stream[i]);

    for (int i = 0; i < NUM_STREAMS; i++) cudaMemcpyAsync(*device_input_ptr + i*input_stream_size, pinned_input + i*input_stream_size, input_stream_size * sizeof(float), cudaMemcpyHostToDevice, stream[i]);
    for (int i = 0; i < NUM_STREAMS; i++) conv_forward_kernel<<<DimGrid, DimBlock, 0, stream[i]>>> (*device_output_ptr + i*output_stream_size, *device_input_ptr + i*input_stream_size, *device_mask_ptr, Batch, Map_out, Channel, Height, Width, K);
    for (int i = 0; i < NUM_STREAMS; i++) cudaMemcpyAsync(pinned_output + i*output_stream_size, *device_output_ptr + i*output_stream_size, output_stream_size * sizeof(float), cudaMemcpyDeviceToHost, stream[i]);

    for (int i = 0; i < NUM_STREAMS; i++) cudaStreamDestroy(stream[i]);

    cudaMemcpy((void *) host_output, pinned_output, Batch * Map_out * Height_out * Width_out * sizeof(float), cudaMemcpyHostToHost);

    cudaFree(*device_input_ptr);
    cudaFree(*device_mask_ptr);
    cudaFree(*device_output_ptr);

    cudaFreeHost(pinned_input);
    cudaFreeHost(pinned_output);

    // We pass double pointers for you to initialize the relevant device pointers,
    //  which are passed to the other two functions.

    // Useful snippet for error checking
    // cudaError_t error = cudaGetLastError();
    // if(error != cudaSuccess)
    // {
    //     std::cout<<"CUDA error: "<<cudaGetErrorString(error)<<std::endl;
    //     exit(-1);
    // }

}


__host__ void GPUInterface::conv_forward_gpu(float *device_output, const float *device_input, const float *device_mask, const int Batch, const int Map_out, const int Channel, const int Height, const int Width, const int K)
{
    // Set the kernel dimensions and call the kernel
    // const int Height_out = Height - K + 1;
    // const int Width_out = Width - K + 1;
    // const int W_grid = (Width_out + TILE_WIDTH - 1) / TILE_WIDTH;
    // const int H_grid = (Height_out + TILE_WIDTH - 1) /TILE_WIDTH;
    // const int Y = H_grid * W_grid;

    // dim3 DimGrid(Map_out, Y, Batch);
    // dim3 DimBlock(TILE_WIDTH, TILE_WIDTH, 1);

    // conv_forward_kernel<<<DimGrid, DimBlock>>>(device_output, device_input, device_mask, Batch, Map_out, Channel, Height, Width, K);
    // cudaDeviceSynchronize();

    return;
}


__host__ void GPUInterface::conv_forward_gpu_epilog(float *host_output, float *device_output, float *device_input, float *device_mask, const int Batch, const int Map_out, const int Channel, const int Height, const int Width, const int K)
{
    // const int Height_out = Height - K + 1;
    // const int Width_out = Width - K + 1;

    // // Copy the output back to host
    // cudaMemcpy(host_output, device_output, Batch * Map_out * Height_out * Width_out * sizeof(float), cudaMemcpyDeviceToHost);

    // // Free device memory
    // cudaFree(device_input);
    // cudaFree(device_mask);
    // cudaFree(device_output);

    return;
}


__host__ void GPUInterface::get_device_properties()
{
    int deviceCount;
    cudaGetDeviceCount(&deviceCount);

    for(int dev = 0; dev < deviceCount; dev++)
    {
        cudaDeviceProp deviceProp;
        cudaGetDeviceProperties(&deviceProp, dev);

        std::cout<<"Device "<<dev<<" name: "<<deviceProp.name<<std::endl;
        std::cout<<"Computational capabilities: "<<deviceProp.major<<"."<<deviceProp.minor<<std::endl;
        std::cout<<"Max Global memory size: "<<deviceProp.totalGlobalMem<<std::endl;
        std::cout<<"Max Constant memory size: "<<deviceProp.totalConstMem<<std::endl;
        std::cout<<"Max Shared memory size per block: "<<deviceProp.sharedMemPerBlock<<std::endl;
        std::cout<<"Max threads per block: "<<deviceProp.maxThreadsPerBlock<<std::endl;
        std::cout<<"Max block dimensions: "<<deviceProp.maxThreadsDim[0]<<" x, "<<deviceProp.maxThreadsDim[1]<<" y, "<<deviceProp.maxThreadsDim[2]<<" z"<<std::endl;
        std::cout<<"Max grid dimensions: "<<deviceProp.maxGridSize[0]<<" x, "<<deviceProp.maxGridSize[1]<<" y, "<<deviceProp.maxGridSize[2]<<" z"<<std::endl;
        std::cout<<"Warp Size: "<<deviceProp.warpSize<<std::endl;
    }
}