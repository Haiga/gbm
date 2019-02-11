//
// Created by jiashuai on 17-9-16.
//

#ifndef THUNDERGBM_SYNCMEM_H
#define THUNDERGBM_SYNCMEM_H

#include "common.h"
#include "cub/util_allocator.cuh"

using namespace cub;
namespace thunder {

    inline void device_mem_copy(void *dst, const void *src, size_t size) {
#ifdef USE_CUDA
        CUDA_CHECK(cudaMemcpy(dst, src, size, cudaMemcpyDefault));
#else
        NO_GPU;
#endif
    }

    class DeviceAllocator : public CachingDeviceAllocator {
    public:
        DeviceAllocator(unsigned int bin_growth, unsigned int min_bin, unsigned int max_bin, size_t max_cached_bytes,
                        bool skip_cleanup, bool debug) : CachingDeviceAllocator(bin_growth, min_bin, max_bin,
                                                                                max_cached_bytes, skip_cleanup,
                                                                                debug) {};

        cudaError_t DeviceAllocate(int device, void **d_ptr, size_t bytes, cudaStream_t active_stream = 0);

        cudaError_t DeviceAllocate(void **d_ptr, size_t bytes, cudaStream_t active_stream = 0);
    };

    class HostAllocator : public CachingDeviceAllocator {
    public:
        HostAllocator(unsigned int bin_growth, unsigned int min_bin, unsigned int max_bin, size_t max_cached_bytes,
                      bool skip_cleanup, bool debug) : CachingDeviceAllocator(bin_growth, min_bin, max_bin,
                                                                              max_cached_bytes, skip_cleanup, debug) {};

        cudaError_t DeviceAllocate(int device, void **d_ptr, size_t bytes, cudaStream_t active_stream = 0);

        cudaError_t DeviceAllocate(void **d_ptr, size_t bytes, cudaStream_t active_stream = 0);

        cudaError_t DeviceFree(int device, void *d_ptr);

        cudaError_t DeviceFree(void *d_ptr);

        cudaError_t FreeAllCached();

        ~HostAllocator() override;
    };

    /**
     * @brief Auto-synced memory for CPU and GPU
     */
    class SyncMem {
    public:
        SyncMem();

        /**
         * create a piece of synced memory with given size. The GPU/CPU memory will not be allocated immediately, but
         * allocated when it is used at first time.
         * @param size the size of memory (in Bytes)
         */
        explicit SyncMem(size_t size);

        ~SyncMem();

        ///return raw host pointer
        void *host_data();

        ///return raw device pointer
        void *device_data();

        /**
         * set host data pointer to another host pointer, and its memory will not be managed by this class
         * @param data another host pointer
         */
        void set_host_data(void *data);

        /**
         * set device data pointer to another device pointer, and its memory will not be managed by this class
         * @param data another device pointer
         */
        void set_device_data(void *data);

        ///transfer data to host
        void to_host();

        ///transfer data to device
        void to_device();

        ///return the size of memory
        size_t size() const;

        ///to determine the where the newest data locates in
        enum HEAD {
            HOST, DEVICE, UNINITIALIZED
        };

        HEAD head() const;

        int get_owner_id() const {
            return device_id;
        }

        static void clear_cache() { device_allocator.FreeAllCached(); };

    private:
        void *device_ptr;
        void *host_ptr;
        bool own_device_data;
        bool own_host_data;
        size_t size_;
        HEAD head_;
        int device_id;
        static DeviceAllocator device_allocator;
        static HostAllocator host_allocator;

        inline void malloc_host(void **ptr, size_t size);

        inline void free_host(void *ptr);

    };
}
using thunder::SyncMem;
#endif //THUNDERGBM_SYNCMEM_H
