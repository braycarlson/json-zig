#pragma once

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <functional>
#include <sstream>
#include <string>
#include <vector>

namespace harness {

constexpr std::uint64_t ns_per_ms = 1000000;
constexpr std::uint32_t run_count_max = 1000000;
constexpr std::uint32_t run_count_min = 20;
constexpr std::uint64_t time_ms_min_default = 1000;
constexpr std::uint64_t time_ms_min_max = 60000;
constexpr std::uint32_t warmup_count = 3;

static_assert(time_ms_min_default > 0);
static_assert(time_ms_min_default <= time_ms_min_max);

inline std::uint64_t time_ns_min = 0;

inline bool arguments_read(int argc, char** argv) {
    if (argc < 3 || argc > 4) return false;

    if (argc == 3) {
        time_ns_min = time_ms_min_default * ns_per_ms;

        return true;
    }

    const char* text = argv[3];
    char* end = nullptr;
    const unsigned long long time_ms_min = std::strtoull(text, &end, 10);

    if (end == text || *end != '\0') return false;
    if (time_ms_min == 0 || time_ms_min > time_ms_min_max) return false;

    time_ns_min = time_ms_min * ns_per_ms;

    return true;
}

inline std::string input_read(const char* path) {
    std::ifstream stream(path, std::ios::binary);

    if (!stream) {
        std::fprintf(stderr, "cannot read %s\n", path);
        std::exit(2);
    }

    std::ostringstream buffer;

    buffer << stream.rdbuf();

    return buffer.str();
}

struct Fnv {
    std::uint64_t state = 0xcbf29ce484222325ull;

    void boolean(bool value) {
        byte(value ? 1 : 0);
    }

    void byte(std::uint8_t value) {
        state ^= value;
        state *= 0x100000001b3ull;
    }

    std::string hex() const {
        char buffer[32];

        std::snprintf(buffer, sizeof buffer, "%016llx", static_cast<unsigned long long>(state));

        return buffer;
    }

    void integer(std::uint64_t value) {
        for (int shift = 0; shift < 64; shift += 8) {
            byte(static_cast<std::uint8_t>(value >> shift));
        }
    }

    void text(const char* data, std::size_t size) {
        integer(size);

        for (std::size_t index = 0; index < size; index++) {
            byte(static_cast<std::uint8_t>(data[index]));
        }
    }

    template <typename Text>
    void text(const Text& value) {
        text(value.data(), value.size());
    }
};

template <typename Value>
inline void do_not_optimize(const Value& value) {
    asm volatile("" : : "r,m"(value) : "memory");
}

inline void measure(
    std::uint64_t bytes,
    const std::function<void()>& prepare,
    const std::function<std::uint64_t()>& run,
    const std::function<std::string()>& checksum
) {
    if (time_ns_min == 0 || time_ns_min > time_ms_min_max * ns_per_ms) {
        std::fprintf(stderr, "the minimum measured time was never read from the arguments\n");
        std::exit(2);
    }

    for (std::uint32_t index = 0; index < warmup_count; index++) {
        prepare();
        do_not_optimize(run());
    }

    std::vector<std::uint64_t> samples;
    std::uint64_t total_ns = 0;

    samples.reserve(run_count_max);

    while (samples.size() < run_count_max) {
        if (samples.size() >= run_count_min && total_ns >= time_ns_min) break;

        prepare();

        const auto start = std::chrono::steady_clock::now();
        const std::uint64_t live = run();
        const auto end = std::chrono::steady_clock::now();

        do_not_optimize(live);

        const auto elapsed_ns = static_cast<std::uint64_t>(
            std::chrono::duration_cast<std::chrono::nanoseconds>(end - start).count()
        );

        samples.push_back(elapsed_ns);
        total_ns += elapsed_ns;
    }

    std::sort(samples.begin(), samples.end());

    const std::string sum = checksum();

    std::printf(
        "bytes=%llu runs=%zu best_ns=%llu median_ns=%llu checksum=%s\n",
        static_cast<unsigned long long>(bytes),
        samples.size(),
        static_cast<unsigned long long>(samples.front()),
        static_cast<unsigned long long>(samples[samples.size() / 2]),
        sum.c_str()
    );
}

inline void measure(
    std::uint64_t bytes,
    const std::function<std::uint64_t()>& run,
    const std::function<std::string()>& checksum
) {
    measure(bytes, [] {}, run, checksum);
}

}
