/*
 * Standalone HEIF stress test for debugging Intel-specific crashes.
 *
 * Build with Zig:
 *   zig build-exe tools/heif_stress_test.c -lheif -lde265 -lc++ -lc
 *
 * Or with gcc (after installing libheif-dev):
 *   gcc -o heif_stress tools/heif_stress_test.c -lheif -lpthread
 *
 * Run:
 *   ./heif_stress ground_truth_examples/heic/sample.heic 100 4
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <signal.h>
#include <execinfo.h>
#include <unistd.h>
#include <libheif/heif.h>

#define MAX_THREADS 32
#define DEFAULT_ITERATIONS 100
#define DEFAULT_THREADS 4

/* Global for signal handler */
static const char* g_filename = NULL;

/* Signal handler to print stack trace on crash */
void crash_handler(int sig) {
    void *array[50];
    size_t size;

    fprintf(stderr, "\n\n=== CRASH DETECTED ===\n");
    fprintf(stderr, "Signal: %d (%s)\n", sig,
            sig == SIGABRT ? "SIGABRT" :
            sig == SIGSEGV ? "SIGSEGV" :
            sig == SIGBUS ? "SIGBUS" : "other");
    fprintf(stderr, "File: %s\n\n", g_filename ? g_filename : "unknown");

    /* Get backtrace */
    size = backtrace(array, 50);
    fprintf(stderr, "Stack trace (%zu frames):\n", size);
    backtrace_symbols_fd(array, size, STDERR_FILENO);

    fprintf(stderr, "\n=== END CRASH ===\n");
    _exit(1);
}

struct thread_arg {
    const uint8_t* data;
    size_t size;
    int thread_id;
    int iterations;
    int success_count;
    int fail_count;
    char error_msg[256];
};

void* decode_thread(void* arg) {
    struct thread_arg* targ = (struct thread_arg*)arg;
    targ->success_count = 0;
    targ->fail_count = 0;
    targ->error_msg[0] = '\0';

    fprintf(stderr, "[Thread %d] Starting %d iterations\n",
            targ->thread_id, targ->iterations);
    fflush(stderr);

    for (int i = 0; i < targ->iterations; i++) {
        /* Create context */
        heif_context* ctx = heif_context_alloc();
        if (!ctx) {
            snprintf(targ->error_msg, sizeof(targ->error_msg),
                     "Failed to allocate context");
            targ->fail_count++;
            continue;
        }

        /* Disable threading */
        heif_context_set_max_decoding_threads(ctx, 0);

        /* Read from memory */
        struct heif_error err = heif_context_read_from_memory_without_copy(
            ctx, targ->data, targ->size, NULL);
        if (err.code != heif_error_Ok) {
            heif_context_free(ctx);
            targ->fail_count++;
            continue;
        }

        /* Get primary image handle */
        heif_image_handle* handle = NULL;
        err = heif_context_get_primary_image_handle(ctx, &handle);
        if (err.code != heif_error_Ok || !handle) {
            heif_context_free(ctx);
            targ->fail_count++;
            continue;
        }

        /* Allocate decoding options with threading disabled */
        struct heif_decoding_options* options = heif_decoding_options_alloc();
        if (options) {
            /* Version 5 added num_threads field */
            if (options->version >= 5) {
                /* This field controls libde265 worker threads */
                /* Note: field name may vary by libheif version */
            }
        }

        fprintf(stderr, "[Thread %d] Iteration %d: decoding...\n",
                targ->thread_id, i);
        fflush(stderr);

        /* Decode image - THIS IS WHERE THE CRASH HAPPENS */
        heif_image* image = NULL;
        err = heif_decode_image(handle, &image, heif_colorspace_RGB,
                                heif_chroma_interleaved_RGBA, options);

        if (options) {
            heif_decoding_options_free(options);
        }

        if (err.code != heif_error_Ok || !image) {
            snprintf(targ->error_msg, sizeof(targ->error_msg),
                     "Decode failed at iteration %d: %s",
                     i, err.message ? err.message : "unknown");
            heif_image_handle_release(handle);
            heif_context_free(ctx);
            targ->fail_count++;
            continue;
        }

        /* Success - clean up */
        heif_image_release(image);
        heif_image_handle_release(handle);
        heif_context_free(ctx);

        targ->success_count++;

        if ((i + 1) % 10 == 0) {
            fprintf(stderr, "[Thread %d] %d/%d iterations complete\n",
                    targ->thread_id, i + 1, targ->iterations);
            fflush(stderr);
        }
    }

    fprintf(stderr, "[Thread %d] Done: %d success, %d fail\n",
            targ->thread_id, targ->success_count, targ->fail_count);
    fflush(stderr);

    return NULL;
}

int main(int argc, char** argv) {
    if (argc < 2) {
        fprintf(stderr, "Usage: %s <heic_file> [iterations] [threads]\n", argv[0]);
        fprintf(stderr, "  iterations: decode cycles per thread (default: %d)\n",
                DEFAULT_ITERATIONS);
        fprintf(stderr, "  threads: concurrent threads (default: %d, max: %d)\n",
                DEFAULT_THREADS, MAX_THREADS);
        return 1;
    }

    const char* filename = argv[1];
    int iterations = (argc > 2) ? atoi(argv[2]) : DEFAULT_ITERATIONS;
    int num_threads = (argc > 3) ? atoi(argv[3]) : DEFAULT_THREADS;

    if (num_threads > MAX_THREADS) num_threads = MAX_THREADS;
    if (num_threads < 1) num_threads = 1;
    if (iterations < 1) iterations = 1;

    g_filename = filename;

    /* Install signal handlers */
    signal(SIGABRT, crash_handler);
    signal(SIGSEGV, crash_handler);
    signal(SIGBUS, crash_handler);

    printf("HEIF Stress Test\n");
    printf("================\n");
    printf("File: %s\n", filename);
    printf("Iterations per thread: %d\n", iterations);
    printf("Threads: %d\n", num_threads);
    printf("Total decodes: %d\n", iterations * num_threads);
    printf("\n");

    /* Initialize libheif */
    heif_init(NULL);

    /* Read file */
    FILE* f = fopen(filename, "rb");
    if (!f) {
        fprintf(stderr, "Error: Cannot open file: %s\n", filename);
        return 1;
    }

    fseek(f, 0, SEEK_END);
    size_t size = ftell(f);
    fseek(f, 0, SEEK_SET);

    printf("File size: %zu bytes\n", size);

    uint8_t* data = malloc(size);
    if (!data) {
        fprintf(stderr, "Error: Cannot allocate memory\n");
        fclose(f);
        return 1;
    }

    if (fread(data, 1, size, f) != size) {
        fprintf(stderr, "Error: Cannot read file\n");
        free(data);
        fclose(f);
        return 1;
    }
    fclose(f);

    /* First, do a single decode to verify it works */
    printf("\nSingle decode warmup...\n");
    fflush(stdout);

    heif_context* ctx = heif_context_alloc();
    heif_context_set_max_decoding_threads(ctx, 0);
    struct heif_error err = heif_context_read_from_memory_without_copy(ctx, data, size, NULL);
    if (err.code != heif_error_Ok) {
        fprintf(stderr, "Error: Failed to parse HEIF: %s\n", err.message);
        free(data);
        return 1;
    }

    heif_image_handle* handle = NULL;
    err = heif_context_get_primary_image_handle(ctx, &handle);
    if (err.code != heif_error_Ok) {
        fprintf(stderr, "Error: Failed to get primary image: %s\n", err.message);
        heif_context_free(ctx);
        free(data);
        return 1;
    }

    int width = heif_image_handle_get_width(handle);
    int height = heif_image_handle_get_height(handle);
    printf("Image dimensions: %dx%d\n", width, height);

    heif_image* image = NULL;
    struct heif_decoding_options* opts = heif_decoding_options_alloc();
    err = heif_decode_image(handle, &image, heif_colorspace_RGB,
                            heif_chroma_interleaved_RGBA, opts);
    heif_decoding_options_free(opts);

    if (err.code != heif_error_Ok) {
        fprintf(stderr, "Error: Warmup decode failed: %s\n", err.message);
        heif_image_handle_release(handle);
        heif_context_free(ctx);
        free(data);
        return 1;
    }

    heif_image_release(image);
    heif_image_handle_release(handle);
    heif_context_free(ctx);

    printf("Warmup successful!\n\n");
    printf("Starting stress test with %d threads...\n", num_threads);
    fflush(stdout);

    /* Create threads */
    pthread_t threads[MAX_THREADS];
    struct thread_arg args[MAX_THREADS];

    for (int i = 0; i < num_threads; i++) {
        args[i].data = data;
        args[i].size = size;
        args[i].thread_id = i;
        args[i].iterations = iterations;
        pthread_create(&threads[i], NULL, decode_thread, &args[i]);
    }

    /* Wait for all threads */
    int total_success = 0;
    int total_fail = 0;

    for (int i = 0; i < num_threads; i++) {
        pthread_join(threads[i], NULL);
        total_success += args[i].success_count;
        total_fail += args[i].fail_count;

        if (args[i].error_msg[0]) {
            printf("Thread %d error: %s\n", i, args[i].error_msg);
        }
    }

    printf("\n=== Results ===\n");
    printf("Total success: %d\n", total_success);
    printf("Total fail: %d\n", total_fail);
    printf("Success rate: %.2f%%\n",
           100.0 * total_success / (total_success + total_fail));

    free(data);
    heif_deinit();

    return (total_fail > 0) ? 1 : 0;
}
