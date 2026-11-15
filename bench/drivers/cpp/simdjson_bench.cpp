#include <string_view>

#include "harness.hpp"
#include "models.hpp"
#include "simdjson.h"

using namespace simdjson;

using Canada = CanadaT<std::string_view>;
using Feature = FeatureT<std::string_view>;
using Status = StatusT<std::string_view>;
using Twitter = TwitterT<std::string_view>;
using User = UserT<std::string_view>;

static std::uint64_t dom_count(dom::element root) {
    std::vector<dom::element> stack{root};
    std::uint64_t count = 0;

    while (!stack.empty()) {
        dom::element element = stack.back();

        stack.pop_back();
        count += 1;

        if (element.is_object()) {
            for (auto field : dom::object(element)) {
                count += 1;
                stack.push_back(field.value);
            }
        } else if (element.is_array()) {
            for (auto child : dom::array(element)) {
                stack.push_back(child);
            }
        }
    }

    return count;
}

static std::vector<std::uint32_t> indices_read(ondemand::value value) {
    std::vector<std::uint32_t> indices;

    for (auto index : value.get_array()) {
        indices.push_back(static_cast<std::uint32_t>(index.get_uint64()));
    }

    return indices;
}

template <typename Target>
static void optional_text_read(ondemand::object& object, std::string_view key, Target& target) {
    ondemand::value value;
    const error_code error = object[key].get(value);

    if (error == NO_SUCH_FIELD) return;
    if (error) throw simdjson_error(error);

    if (value.is_null()) {
        target.reset();
    } else {
        target = std::string_view(value.get_string());
    }
}

template <typename Integer, typename Target>
static void optional_integer_read(ondemand::object& object, std::string_view key, Target& target) {
    ondemand::value value;
    const error_code error = object[key].get(value);

    if (error == NO_SUCH_FIELD) return;
    if (error) throw simdjson_error(error);

    if (value.is_null()) {
        target.reset();
    } else if constexpr (std::is_signed_v<Integer>) {
        target = static_cast<Integer>(value.get_int64());
    } else {
        target = static_cast<Integer>(value.get_uint64());
    }
}

static void user_read(ondemand::object object, User& user) {
    user.id = object["id"].get_uint64();
    user.id_str = object["id_str"].get_string();
    user.name = object["name"].get_string();
    user.screen_name = object["screen_name"].get_string();
    user.location = object["location"].get_string();
    user.description = object["description"].get_string();
    optional_text_read(object, "url", user.url);
    user.protected_ = object["protected"].get_bool();
    user.followers_count = object["followers_count"].get_uint64();
    user.friends_count = object["friends_count"].get_uint64();
    user.listed_count = object["listed_count"].get_uint64();
    user.created_at = object["created_at"].get_string();
    user.favourites_count = object["favourites_count"].get_uint64();
    optional_integer_read<std::int64_t>(object, "utc_offset", user.utc_offset);
    optional_text_read(object, "time_zone", user.time_zone);
    user.geo_enabled = object["geo_enabled"].get_bool();
    user.verified = object["verified"].get_bool();
    user.statuses_count = object["statuses_count"].get_uint64();
    user.lang = object["lang"].get_string();
}

static void entities_read(ondemand::object object, EntitiesT<std::string_view>& entities) {
    for (auto value : object["hashtags"].get_array()) {
        ondemand::object hashtag = value.get_object();
        HashtagT<std::string_view> item;

        item.text = hashtag["text"].get_string();
        item.indices = indices_read(hashtag["indices"]);
        entities.hashtags.push_back(std::move(item));
    }

    for (auto value : object["urls"].get_array()) {
        ondemand::object url = value.get_object();
        LinkT<std::string_view> item;

        item.url = url["url"].get_string();
        item.expanded_url = url["expanded_url"].get_string();
        item.display_url = url["display_url"].get_string();
        item.indices = indices_read(url["indices"]);
        entities.urls.push_back(std::move(item));
    }

    for (auto value : object["user_mentions"].get_array()) {
        ondemand::object mention = value.get_object();
        MentionT<std::string_view> item;

        item.screen_name = mention["screen_name"].get_string();
        item.name = mention["name"].get_string();
        item.id = mention["id"].get_uint64();
        item.indices = indices_read(mention["indices"]);
        entities.user_mentions.push_back(std::move(item));
    }
}

static void status_read(ondemand::object object, Status& status) {
    status.created_at = object["created_at"].get_string();
    status.id = object["id"].get_uint64();
    status.id_str = object["id_str"].get_string();
    status.text = object["text"].get_string();
    status.source = object["source"].get_string();
    status.truncated = object["truncated"].get_bool();
    optional_integer_read<std::uint64_t>(object, "in_reply_to_status_id", status.in_reply_to_status_id);
    optional_integer_read<std::uint64_t>(object, "in_reply_to_user_id", status.in_reply_to_user_id);
    optional_text_read(object, "in_reply_to_screen_name", status.in_reply_to_screen_name);
    user_read(object["user"].get_object(), status.user);
    status.retweet_count = object["retweet_count"].get_uint64();
    status.favorite_count = object["favorite_count"].get_uint64();
    entities_read(object["entities"].get_object(), status.entities);
    status.favorited = object["favorited"].get_bool();
    status.retweeted = object["retweeted"].get_bool();
    status.lang = object["lang"].get_string();
}

static void twitter_read(ondemand::document& document, Twitter& twitter) {
    ondemand::object root = document.get_object();

    for (auto value : root["statuses"].get_array()) {
        twitter.statuses.emplace_back();
        status_read(value.get_object(), twitter.statuses.back());
    }

    ondemand::object metadata = root["search_metadata"].get_object();
    auto& target = twitter.search_metadata;

    target.completed_in = metadata["completed_in"].get_double();
    target.max_id = metadata["max_id"].get_uint64();
    target.max_id_str = metadata["max_id_str"].get_string();
    target.next_results = metadata["next_results"].get_string();
    target.query = metadata["query"].get_string();
    target.refresh_url = metadata["refresh_url"].get_string();
    target.count = metadata["count"].get_uint64();
    target.since_id = metadata["since_id"].get_uint64();
    target.since_id_str = metadata["since_id_str"].get_string();
}

static void ring_read(ondemand::value value, std::vector<std::array<double, 2>>& ring) {
    for (auto point_value : value.get_array()) {
        std::array<double, 2> point{};
        std::size_t count = 0;

        for (auto number : point_value.get_array()) {
            if (count >= point.size()) throw simdjson_error(INCORRECT_TYPE);

            point[count] = number.get_double();
            count += 1;
        }

        if (count != point.size()) throw simdjson_error(INCORRECT_TYPE);

        ring.push_back(point);
    }
}

static void canada_read(ondemand::document& document, Canada& canada) {
    ondemand::object root = document.get_object();

    canada.type = root["type"].get_string();

    for (auto value : root["features"].get_array()) {
        ondemand::object object = value.get_object();
        Feature& feature = canada.features.emplace_back();

        feature.type = object["type"].get_string();
        feature.properties.name = object["properties"].get_object()["name"].get_string();

        ondemand::object geometry = object["geometry"].get_object();

        feature.geometry.type = geometry["type"].get_string();

        for (auto ring : geometry["coordinates"].get_array()) {
            ring_read(ring.value(), feature.geometry.coordinates.emplace_back());
        }
    }
}

static int write_measure(const std::string& input) {
    dom::parser parser;
    dom::element element = parser.parse(padded_string(input));
    simdjson::internal::string_builder<> builder;
    std::uint64_t length = 0;

    auto write = [&]() -> std::uint64_t {
        builder.clear();
        builder.append(element);
        length = builder.str().size();

        return length;
    };

    const std::uint64_t bytes = write();

    harness::measure(bytes, write, [&]() { return std::to_string(length); });

    return 0;
}

template <typename Value>
static int decode_measure(
    const padded_string& input,
    void (*read)(ondemand::document&, Value&),
    void (*feed)(harness::Fnv&, const Value&)
) {
    ondemand::parser parser;
    ondemand::document document;
    Value value;

    auto run = [&]() -> std::uint64_t {
        document = parser.iterate(input);
        read(document, value);

        return 1;
    };

    auto checksum = [&]() -> std::string {
        harness::Fnv fnv;

        feed(fnv, value);

        return fnv.hex();
    };

    harness::measure(input.size(), [&]() { value = Value{}; }, run, checksum);

    return 0;
}

static int document_measure(const padded_string& input) {
    dom::parser parser;

    auto run = [&]() -> std::uint64_t {
        dom::element root = parser.parse(input);

        harness::do_not_optimize(root);

        return 1;
    };

    harness::measure(input.size(), run, [&]() { return std::to_string(dom_count(parser.parse(input))); });

    return 0;
}

static int mode_run(const std::string& mode, const std::string& file) {
    if (mode == "write") return write_measure(file);

    const padded_string input(file);

    if (mode == "decode-canada") return decode_measure<Canada>(input, canada_read, canada_feed<std::string_view>);
    if (mode == "decode-twitter") return decode_measure<Twitter>(input, twitter_read, twitter_feed<std::string_view>);
    if (mode == "document") return document_measure(input);

    return 2;
}

int main(int argc, char** argv) {
    if (!harness::arguments_read(argc, argv)) return 2;

    try {
        return mode_run(argv[1], harness::input_read(argv[2]));
    } catch (const simdjson::simdjson_error& error) {
        std::fprintf(stderr, "%s\n", error.what());

        return 1;
    }
}
