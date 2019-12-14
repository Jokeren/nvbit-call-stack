/* Copyright (c) 2019, NVIDIA CORPORATION. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 *  * Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 *  * Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *  * Neither the name of NVIDIA CORPORATION nor the names of its
 *    contributors may be used to endorse or promote products derived
 *    from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE COPYRIGHT OWNER OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#include <assert.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>

/* every tool needs to include this once */
#include "nvbit_tool.h"

/* nvbit interface file */
#include "nvbit.h"

/* nvbit utility functions */
#include "utils/utils.h"

/* for channel */
#include "utils/channel.hpp"

#include "calling_context_tree.h"

enum CallTraceFlags {
  CALL_TRACE_INST = 1,
  CALL_TRACE_CALL = 2,
  CALL_TRACE_RET = 4
};

typedef struct {
  uint64_t func_addr;
  int g_warp_id;
  int offset;
  // 1: normal, 2: call, 4: ret
  int flags;
} call_trace_t;

/* Channel used to communicate from GPU to CPU receiving thread */
#define CHANNEL_SIZE ((1l << 10) * sizeof(call_trace_t))
static __managed__ ChannelDev channel_dev;
static ChannelHost channel_host;

/* receiving thread and its control variables */
pthread_t recv_thread;
volatile bool recv_thread_started = false;
volatile bool recv_thread_receiving = false;

/* skip flag used to avoid re-entry on the nvbit_callback when issuing
 * flush_channel kernel call */
volatile bool skip_flag = false;

/* kernel id counter, maintained in system memory */
uint32_t kernel_id = 0;

/* total instruction counter, maintained in system memory, incremented by
 * "counter" every time a kernel completes  */
uint64_t tot_app_instrs = 0;

uint64_t bb_index = 0;

/* kernel instruction counter, updated by the GPU threads */
__managed__ uint64_t counter = 0;

/* global control variables for this tool */
uint32_t ker_begin_interval = 0;
uint32_t ker_end_interval = UINT32_MAX;
int verbose = 0;
int count_warp_level = 1;
int exclude_pred_off = 0;

#define CALL_STACK_DEBUG 1

/* a pthread mutex, used to prevent multiple kernels to run concurrently and
 * therefore to "corrupt" the counter variable */
pthread_mutex_t mutex;

/* instrumentation function that we want to inject, please note the use of
 * 1. "extern "C" __device__ __noinline__" to prevent code elimination by the
 * compiler.
 * 2. NVBIT_EXPORT_FUNC(count_instrs) to notify nvbit the name of the function
 * we want to inject. This name must match exactly the function name */
extern "C" __device__ __noinline__ void count_instrs(uint64_t func_addr,
  int offset,
  int num_instrs,
  int count_warp_level) {
  /* all the active threads will compute the active mask */
  const int active_mask = __ballot(1);
  /* each thread will get a lane id (get_lane_id is in utils/utils.h) */
  const int laneid = get_laneid();
  /* get the id of the first active thread */
  const int first_laneid = __ffs(active_mask) - 1;
  /* count all the active thread */
  const int num_threads = __popc(active_mask);
  /* only the first active thread will perform the atomic */
  if (first_laneid == laneid) {
    if (count_warp_level) {
      atomicAdd((unsigned long long *)&counter, 1 * num_instrs);
    } else {
      atomicAdd((unsigned long long *)&counter, num_threads * num_instrs);
    }

    call_trace_t call_trace;
    call_trace.func_addr = func_addr;
    call_trace.g_warp_id = get_global_warp_id();
    call_trace.offset = offset;
    call_trace.flags = CALL_TRACE_INST;

    channel_dev.push(&call_trace, sizeof(call_trace_t));

    if (CALL_STACK_DEBUG) {
      printf("warp %d at function 0x%lx:0x%x\n", call_trace.g_warp_id,
        call_trace.func_addr, call_trace.offset);
    }
  }
}
NVBIT_EXPORT_FUNC(count_instrs)

extern "C" __device__ __noinline__ void count_pred_off(int predicate,
  int count_warp_level) {
  const int active_mask = __ballot(1);

  const int laneid = get_laneid();

  const int first_laneid = __ffs(active_mask) - 1;

  const int predicate_mask = __ballot(predicate);

  const int mask_off = active_mask ^ predicate_mask;

  const int num_threads_off = __popc(mask_off);
  if (first_laneid == laneid) {
    if (count_warp_level) {
      /* if the predicate mask was off we reduce the count of 1 */
      if (predicate_mask == 0)
        atomicAdd((unsigned long long *)&counter, -1);
    } else {
      atomicAdd((unsigned long long *)&counter, -num_threads_off);
    }
    }
  }
NVBIT_EXPORT_FUNC(count_pred_off)

extern "C" __device__ __noinline__ void trace_call(uint64_t func_addr,
  int offset) {
  const int active_mask = __ballot(1);
  const int laneid = get_laneid();
  const int first_laneid = __ffs(active_mask) - 1;

  if (first_laneid == laneid) {
    call_trace_t call_trace;
    call_trace.func_addr = func_addr;
    call_trace.g_warp_id = get_global_warp_id();
    call_trace.offset = offset;
    call_trace.flags = CALL_TRACE_CALL;

    channel_dev.push(&call_trace, sizeof(call_trace_t));

    if (CALL_STACK_DEBUG) {
      printf("warp %d call at function 0x%lx:0x%x\n", call_trace.g_warp_id,
        call_trace.func_addr, call_trace.offset);
    }
  }
}
NVBIT_EXPORT_FUNC(trace_call)

extern "C" __device__ __noinline__ void trace_ret(uint64_t func_addr,
  int offset) {
  const int active_mask = __ballot(1);
  const int laneid = get_laneid();
  const int first_laneid = __ffs(active_mask) - 1;

  if (first_laneid == laneid) {
    call_trace_t call_trace;
    call_trace.func_addr = func_addr;
    call_trace.g_warp_id = get_global_warp_id();
    call_trace.offset = offset;
    call_trace.flags = CALL_TRACE_RET;

    channel_dev.push(&call_trace, sizeof(call_trace_t));

    if (CALL_STACK_DEBUG) {
      printf("warp %d ret at function 0x%lx:0x%x\n", call_trace.g_warp_id,
        call_trace.func_addr, call_trace.offset);
    }
  }
}
NVBIT_EXPORT_FUNC(trace_ret)

  /* nvbit_at_init() is executed as soon as the nvbit tool is loaded. We
   * typically do initializations in this call. In this case for instance we get
   * some environment variables values which we use as input arguments to the tool
   */
  void nvbit_at_init() {
    /* just make sure all managed variables are allocated on GPU */
    setenv("CUDA_MANAGED_FORCE_DEVICE_ALLOC", "1", 1);

    /* we get some environment variables that are going to be use to selectively
     * instrument (within a interval of kernel indexes and instructions). By
     * default we instrument everything. */
    GET_VAR_INT(ker_begin_interval, "KERNEL_BEGIN", 0,
      "Beginning of the kernel launch interval where to apply "
      "instrumentation");
    GET_VAR_INT(
      ker_end_interval, "KERNEL_END", UINT32_MAX,
      "End of the kernel launch interval where to apply instrumentation");
    GET_VAR_INT(count_warp_level, "COUNT_WARP_LEVEL", 1,
      "Count warp level or thread level instructions");
    GET_VAR_INT(exclude_pred_off, "EXCLUDE_PRED_OFF", 0,
      "Exclude predicated off instruction from count");
    GET_VAR_INT(verbose, "TOOL_VERBOSE", 0, "Enable verbosity inside the tool");
    std::string pad(100, '-');
    printf("%s\n", pad.c_str());
  }

/* nvbit_at_function_first_load() is executed every time a function is loaded
 * for the first time. Inside this call-back we typically get the vector of SASS
 * instructions composing the loaded CUfunction. We can iterate on this vector
 * and insert call to instrumentation functions before or after each one of
 * them. */
void nvbit_at_function_first_load(CUcontext ctx, CUfunction func) {
  uint64_t func_addr = nvbit_get_func_addr(func);
  /* Get the static control flow graph of instruction */
  const CFG_t &cfg = nvbit_get_CFG(ctx, func);
  if (cfg.is_degenerate) {
    printf(
      "Warning: Function %s is degenerated, we can't compute basic "
      "blocks statically",
      nvbit_get_func_name(ctx, func));
  }

  if (verbose) {
    printf("Function %s at 0x%lx\n", nvbit_get_func_name(ctx, func), func_addr);
    /* print */
    int cnt = 0;
    for (auto &bb : cfg.bbs) {
      printf("Basic block id %d - num instructions %ld\n", cnt++,
        bb->instrs.size());
      for (auto &i : bb->instrs) {
        i->print(" ");
      }
    }
  }

  if (verbose) {
    printf("inspecting %s - number basic blocks %ld\n",
      nvbit_get_func_name(ctx, func), cfg.bbs.size());
  }

  /* Iterate on basic block and inject the first instruction */
  for (auto &bb : cfg.bbs) {
    Instr *i = bb->instrs[0];
    /* inject device function */
    nvbit_insert_call(i, "count_instrs", IPOINT_BEFORE);
    nvbit_add_call_arg_const_val64(i, func_addr);
    nvbit_add_call_arg_const_val32(i, i->getOffset());
    nvbit_add_call_arg_const_val32(i, bb->instrs.size());
    /* add count warp level option */
    nvbit_add_call_arg_const_val32(i, count_warp_level);
    if (verbose) {
      i->print("Inject count_instr before - ");
    }

    for (auto *i : bb->instrs) { 
      std::string opcode(i->getOpcode());
      if (opcode.find("CAL") != std::string::npos) {
        /* inject device function */
        nvbit_insert_call(i, "trace_call", IPOINT_BEFORE);
        nvbit_add_call_arg_const_val64(i, func_addr);
        nvbit_add_call_arg_const_val32(i, i->getOffset());
        if (verbose) {
          i->print("Inject count_instr before - ");
        }
      }

      if (opcode.find("RET") != std::string::npos) {
        /* inject device function */
        nvbit_insert_call(i, "trace_ret", IPOINT_BEFORE);
        nvbit_add_call_arg_const_val64(i, func_addr);
        nvbit_add_call_arg_const_val32(i, i->getOffset());
        if (verbose) {
          i->print("Inject count_instr before - ");
        }
      }
    }

    ++bb_index;
  }

  if (exclude_pred_off) {
    /* iterate on instructions */
    for (auto i : nvbit_get_instrs(ctx, func)) {
      /* inject only if instruction has predicate */
      if (i->hasPred()) {
        /* inject function */
        nvbit_insert_call(i, "count_pred_off", IPOINT_BEFORE);
        /* add predicate as argument */
        nvbit_add_call_arg_pred_val(i);
        /* add count warp level option */
        nvbit_add_call_arg_const_val32(i, count_warp_level);
        if (verbose) {
          i->print("Inject count_instr before - ");
        }
      }
    }
  }
}

__global__ void flush_channel() {
  /* push memory access with negative cta id to communicate the kernel is
   * completed */
  call_trace_t call_trace;
  call_trace.func_addr = 0;
  channel_dev.push(&call_trace, sizeof(call_trace_t));

  /* flush channel */
  channel_dev.flush();
}

/* This call-back is triggered every time a CUDA driver call is encountered.
 * Here we can look for a particular CUDA driver call by checking at the
 * call back ids  which are defined in tools_cuda_api_meta.h.
 * This call back is triggered bith at entry and at exit of each CUDA driver
 * call, is_exit=0 is entry, is_exit=1 is exit.
 * */
void nvbit_at_cuda_event(CUcontext ctx, int is_exit, nvbit_api_cuda_t cbid,
  const char *name, void *params, CUresult *pStatus) {
  if (skip_flag) return;

  /* Identify all the possible CUDA launch events */
  if (cbid == API_CUDA_cuLaunch || cbid == API_CUDA_cuLaunchKernel_ptsz ||
    cbid == API_CUDA_cuLaunchGrid || cbid == API_CUDA_cuLaunchGridAsync ||
    cbid == API_CUDA_cuLaunchKernel) {
    /* cast params to cuLaunch_params since if we are here we know these are
     * the right parameters type */
    cuLaunch_params *p = (cuLaunch_params *)params;

    if (!is_exit) {
      /* if we are entering in a kernel launch:
       * 1. Lock the mutex to prevent multiple kernels to run concurrently
       * (overriding the counter) in case the user application does that
       * 2. Select if we want to run the instrumented or original
       * version of the kernel
       * 3. Reset the kernel instruction counter */
      pthread_mutex_lock(&mutex);
      if (kernel_id >= ker_begin_interval &&
        kernel_id < ker_end_interval) {
        nvbit_enable_instrumented(ctx, p->f, true);
      } else {
        nvbit_enable_instrumented(ctx, p->f, false);
      }
      counter = 0;
      recv_thread_receiving = true;
    } else {
      /* if we are exiting a kernel launch:
       * 1. Wait until the kernel is completed using
       * cudaDeviceSynchronize()
       * 2. Get number of thread blocks in the kernel
       * 3. Print the thread instruction counters
       * 4. Release the lock*/
      CUDA_SAFECALL(cuCtxSynchronize());
      skip_flag = true;
      flush_channel<<<1, 1>>>();
      printf("Launch kernel %d - %s\n",
        kernel_id++, nvbit_get_func_name(ctx, p->f));
      CUDA_SAFECALL(cuCtxSynchronize());
      skip_flag = false;

      tot_app_instrs += counter;
      int num_ctas = 0;
      if (cbid == API_CUDA_cuLaunchKernel_ptsz ||
        cbid == API_CUDA_cuLaunchKernel) {
        cuLaunchKernel_params *p2 = (cuLaunchKernel_params *)params;
        num_ctas = p2->gridDimX * p2->gridDimY * p2->gridDimZ;
      }
      printf(
        "kernel %d - %s - #thread-blocks %d,  kernel "
        "instructions %ld, total instructions %ld\n",
        kernel_id++, nvbit_get_func_name(ctx, p->f), num_ctas, counter,
        tot_app_instrs);

      /* wait here until the receiving thread has not finished with the
       * current kernel */
      while (recv_thread_receiving) {
        pthread_yield();
      }
      pthread_mutex_unlock(&mutex);
    }
  }
}

void *recv_thread_fun(void *) {
  char *recv_buffer = (char *)malloc(CHANNEL_SIZE);
  CallingContextTree cct;

  while (recv_thread_started) {
    uint32_t num_recv_bytes = 0;
    if (recv_thread_receiving &&
      (num_recv_bytes = channel_host.recv(recv_buffer, CHANNEL_SIZE)) >
      0) {
      uint32_t num_processed_bytes = 0;

      if (CALL_STACK_DEBUG) {
        printf("recv %d bytes\n", num_recv_bytes);
      }

      while (num_processed_bytes < num_recv_bytes) {
        call_trace_t *call_trace =
          (call_trace_t *)&recv_buffer[num_processed_bytes];

        /* when we get this cta_id_x it means the kernel has completed
         */
        if (call_trace->func_addr == 0) {
          recv_thread_receiving = false;
          break;
        }

        if (CALL_STACK_DEBUG) {
          std::cout << "recv" << std::endl;
          std::cout << "warp_id: " << call_trace->g_warp_id << " flags: " << call_trace->flags <<
            " func_addr: 0x" << std::hex << call_trace->func_addr << " offset: 0x" << call_trace->offset << std::endl;
        }
        
        if ((call_trace->flags & CALL_TRACE_CALL)) {
          cct.call(call_trace->g_warp_id, call_trace->func_addr, call_trace->offset);
        } else if ((call_trace->flags & CALL_TRACE_RET)) {
          cct.ret(call_trace->g_warp_id);
        } else {
          cct.block(call_trace->g_warp_id, call_trace->func_addr, call_trace->offset);
        }

        num_processed_bytes += sizeof(call_trace_t);
      }
    }
  }

  if (CALL_STACK_DEBUG) {
    std::cout << "Calling context tree: " << std::endl;
    std::cout << cct.to_string() << std::endl;
  }

  free(recv_buffer);
  return NULL;
}

void nvbit_at_ctx_init(CUcontext ctx) {
  recv_thread_started = true;
  channel_host.init(0, CHANNEL_SIZE, &channel_dev, NULL);
  pthread_create(&recv_thread, NULL, recv_thread_fun, NULL);
}

void nvbit_at_ctx_term(CUcontext ctx) {
  if (recv_thread_started) {
    recv_thread_started = false;
    pthread_join(recv_thread, NULL);
  }
}
