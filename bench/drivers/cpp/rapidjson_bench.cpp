#include <cstring>

#include "harness.hpp"
#include "rapidjson/document.h"
#include "rapidjson/error/en.h"
#include "rapidjson/stringbuffer.h"
#include "rapidjson/writer.h"

using Allocator = rapidjson::MemoryPoolAllocator<>;
using Document = rapidjson::GenericDocument<rapidjson::UTF8<>, Allocator>;

constexpr unsigned parse_flags = rapidjson::kParseFullPrecisionFlag | rapidjson::kParseValidateEncodingFlag;

static std::uint64_t value_count(const Document::ValueType& root) {
    std::vector<const Document::ValueType*> stack{&root};
    std::uint64_t count = 0;

    while (!stack.empty()) {
        const Document::ValueType* value = stack.back();

        stack.pop_back();
        count += 1;

        if (value->IsObject()) {
            for (auto member = value->MemberBegin(); member != value->MemberEnd(); ++member) {
                count += 1;
                stack.push_back(&member->value);
            }
        } else if (value->IsArray()) {
            for (auto element = value->Begin(); element != value->End(); ++element) {
                stack.push_back(element);
            }
        }
    }

    return count;
}

static void parse_check(const Document& document) {
    if (document.HasParseError()) {
        const char* message = rapidjson::GetParseError_En(document.GetParseError());

        std::fprintf(stderr, "%s at %zu\n", message, document.GetErrorOffset());
        std::exit(1);
    }
}

static int document_measure(const std::string& input) {
    std::vector<char> copy(input.size() + 1, 0);
    std::vector<char> buffer(8 * input.size() + (1 << 20));
    Allocator allocator(buffer.data(), buffer.size());
    std::uint64_t state = 0;

    auto prepare = [&]() {
        std::memcpy(copy.data(), input.data(), input.size());
        allocator.Clear();
    };

    auto run = [&]() -> std::uint64_t {
        Document document(&allocator);

        document.ParseInsitu<parse_flags>(copy.data());
        parse_check(document);
        state = document.IsObject() ? document.MemberCount() : document.Size();

        return state;
    };

    auto checksum = [&]() -> std::string {
        prepare();

        Document document(&allocator);

        document.ParseInsitu<parse_flags>(copy.data());
        parse_check(document);

        return std::to_string(value_count(document));
    };

    harness::measure(input.size(), prepare, run, checksum);

    return 0;
}

static int write_measure(const std::string& input) {
    Document document;
    rapidjson::StringBuffer buffer;
    std::uint64_t length = 0;

    document.Parse<parse_flags>(input.data(), input.size());
    parse_check(document);

    auto write = [&]() -> std::uint64_t {
        buffer.Clear();

        rapidjson::Writer<rapidjson::StringBuffer> writer(buffer);

        document.Accept(writer);
        length = buffer.GetSize();

        return length;
    };

    const std::uint64_t bytes = write();

    harness::measure(bytes, write, [&]() { return std::to_string(length); });

    return 0;
}

int main(int argc, char** argv) {
    if (!harness::arguments_read(argc, argv)) return 2;

    const std::string mode = argv[1];
    const std::string input = harness::input_read(argv[2]);

    if (mode == "document") return document_measure(input);
    if (mode == "write") return write_measure(input);

    return 2;
}
