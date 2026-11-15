#include <cstring>

#include "harness.hpp"
#include "yyjson.h"

static yyjson_doc* document_read(char* data, std::size_t size, yyjson_read_flag flags, const yyjson_alc* allocator) {
    yyjson_read_err error;
    yyjson_doc* document = yyjson_read_opts(data, size, flags, allocator, &error);

    if (document == nullptr) {
        std::fprintf(stderr, "%s at %zu\n", error.msg, error.pos);
        std::exit(1);
    }

    return document;
}

static int document_measure(const std::string& input, yyjson_read_flag flags) {
    const yyjson_read_flag flags_insitu = flags | YYJSON_READ_INSITU;
    std::vector<char> copy(input.size() + YYJSON_PADDING_SIZE, 0);
    std::vector<char> pool(yyjson_read_max_memory_usage(input.size(), flags_insitu));
    yyjson_alc allocator;
    yyjson_doc* document = nullptr;
    std::uint64_t state = 0;

    if (!yyjson_alc_pool_init(&allocator, pool.data(), pool.size())) return 1;

    auto prepare = [&]() {
        yyjson_doc_free(document);
        document = nullptr;

        std::memcpy(copy.data(), input.data(), input.size());
    };

    auto run = [&]() -> std::uint64_t {
        document = document_read(copy.data(), input.size(), flags_insitu, &allocator);
        state = yyjson_doc_get_val_count(document);

        return state;
    };

    harness::measure(input.size(), prepare, run, [&]() { return std::to_string(state); });
    yyjson_doc_free(document);

    return 0;
}

static int write_measure(std::string& input, yyjson_read_flag flags) {
    yyjson_doc* document = document_read(input.data(), input.size(), flags, nullptr);
    std::vector<char> output(16 * input.size() + (1 << 20));
    std::uint64_t length = 0;

    auto write = [&]() -> std::uint64_t {
        length = yyjson_write_buf(output.data(), output.size(), document, 0, nullptr);

        return length;
    };

    const std::uint64_t bytes = write();

    if (bytes == 0) return 1;

    harness::measure(bytes, write, [&]() { return std::to_string(length); });

    return 0;
}

int main(int argc, char** argv) {
    if (!harness::arguments_read(argc, argv)) return 2;

    const std::string mode = argv[1];
    std::string input = harness::input_read(argv[2]);

    if (mode == "document") return document_measure(input, 0);
    if (mode == "document-raw") return document_measure(input, YYJSON_READ_NUMBER_AS_RAW);
    if (mode == "write") return write_measure(input, 0);
    if (mode == "write-raw") return write_measure(input, YYJSON_READ_NUMBER_AS_RAW);

    return 2;
}
