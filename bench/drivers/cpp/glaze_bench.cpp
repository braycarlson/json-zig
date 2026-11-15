#include <string>

#include "glaze/glaze.hpp"
#include "harness.hpp"
#include "models.hpp"

using Canada = CanadaT<std::string>;
using Twitter = TwitterT<std::string>;
using User = UserT<std::string>;

template <>
struct glz::meta<User> {
    static constexpr auto modify = glz::object("protected", &User::protected_);
};

struct ReadOptions : glz::opts {
    bool validate_skipped = true;
    bool validate_trailing_whitespace = true;
};

constexpr ReadOptions read_options{{.error_on_unknown_keys = false}};
constexpr glz::opts write_options{.skip_null_members = false};

template <typename Value>
static void read_or_exit(Value& value, const std::string& input) {
    if (auto error = glz::read<read_options>(value, input)) {
        std::fprintf(stderr, "%s\n", glz::format_error(error, input).c_str());
        std::exit(1);
    }
}

template <typename Value>
static int decode_measure(const std::string& input, void (*feed)(harness::Fnv&, const Value&)) {
    static Value value;

    auto run = [&]() -> std::uint64_t {
        read_or_exit(value, input);

        return 1;
    };

    auto checksum = [&]() -> std::string {
        harness::Fnv fnv;

        feed(fnv, value);

        return fnv.hex();
    };

    harness::measure(input.size(), run, checksum);

    return 0;
}

template <typename Value>
static int encode_measure(const std::string& input) {
    static Value value;
    std::string buffer;
    std::uint64_t length = 0;

    read_or_exit(value, input);
    buffer.reserve(16 * input.size() + (1 << 20));

    auto write = [&]() -> std::uint64_t {
        buffer.clear();

        if (auto error = glz::write<write_options>(value, buffer)) std::exit(1);

        length = buffer.size();

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

    if (mode == "decode-canada") return decode_measure<Canada>(input, canada_feed<std::string>);
    if (mode == "decode-twitter") return decode_measure<Twitter>(input, twitter_feed<std::string>);
    if (mode == "encode-canada") return encode_measure<Canada>(input);
    if (mode == "encode-twitter") return encode_measure<Twitter>(input);

    return 2;
}
