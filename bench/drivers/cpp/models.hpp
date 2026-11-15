#pragma once

#include <array>
#include <bit>
#include <cstdint>
#include <optional>
#include <vector>

#include "harness.hpp"

template <typename Text>
struct PropertiesT {
    Text name{};
};

template <typename Text>
struct GeometryT {
    Text type{};
    std::vector<std::vector<std::array<double, 2>>> coordinates;
};

template <typename Text>
struct FeatureT {
    Text type{};
    PropertiesT<Text> properties;
    GeometryT<Text> geometry;
};

template <typename Text>
struct CanadaT {
    Text type{};
    std::vector<FeatureT<Text>> features;
};

template <typename Text>
struct HashtagT {
    Text text{};
    std::vector<std::uint32_t> indices;
};

template <typename Text>
struct MentionT {
    Text screen_name{};
    Text name{};
    std::uint64_t id = 0;
    std::vector<std::uint32_t> indices;
};

template <typename Text>
struct LinkT {
    Text url{};
    Text expanded_url{};
    Text display_url{};
    std::vector<std::uint32_t> indices;
};

template <typename Text>
struct EntitiesT {
    std::vector<HashtagT<Text>> hashtags;
    std::vector<LinkT<Text>> urls;
    std::vector<MentionT<Text>> user_mentions;
};

template <typename Text>
struct UserT {
    std::uint64_t id = 0;
    Text id_str{};
    Text name{};
    Text screen_name{};
    Text location{};
    Text description{};
    std::optional<Text> url;
    bool protected_ = false;
    std::uint64_t followers_count = 0;
    std::uint64_t friends_count = 0;
    std::uint64_t listed_count = 0;
    Text created_at{};
    std::uint64_t favourites_count = 0;
    std::optional<std::int64_t> utc_offset;
    std::optional<Text> time_zone;
    bool geo_enabled = false;
    bool verified = false;
    std::uint64_t statuses_count = 0;
    Text lang{};
};

template <typename Text>
struct StatusT {
    Text created_at{};
    std::uint64_t id = 0;
    Text id_str{};
    Text text{};
    Text source{};
    bool truncated = false;
    std::optional<std::uint64_t> in_reply_to_status_id;
    std::optional<std::uint64_t> in_reply_to_user_id;
    std::optional<Text> in_reply_to_screen_name;
    UserT<Text> user;
    std::uint64_t retweet_count = 0;
    std::uint64_t favorite_count = 0;
    EntitiesT<Text> entities;
    bool favorited = false;
    bool retweeted = false;
    Text lang{};
};

template <typename Text>
struct SearchMetadataT {
    double completed_in = 0;
    std::uint64_t max_id = 0;
    Text max_id_str{};
    Text next_results{};
    Text query{};
    Text refresh_url{};
    std::uint64_t count = 0;
    std::uint64_t since_id = 0;
    Text since_id_str{};
};

template <typename Text>
struct TwitterT {
    std::vector<StatusT<Text>> statuses;
    SearchMetadataT<Text> search_metadata;
};

template <typename Text>
inline void canada_feed(harness::Fnv& fnv, const CanadaT<Text>& canada) {
    fnv.text(canada.type);
    fnv.integer(canada.features.size());

    for (const auto& feature : canada.features) {
        fnv.text(feature.type);
        fnv.text(feature.properties.name);
        fnv.text(feature.geometry.type);
        fnv.integer(feature.geometry.coordinates.size());

        for (const auto& ring : feature.geometry.coordinates) {
            fnv.integer(ring.size());

            for (const auto& point : ring) {
                fnv.integer(std::bit_cast<std::uint64_t>(point[0]));
                fnv.integer(std::bit_cast<std::uint64_t>(point[1]));
            }
        }
    }
}

template <typename Text>
inline void optional_text_feed(harness::Fnv& fnv, const std::optional<Text>& value) {
    if (value) {
        fnv.byte(1);
        fnv.text(*value);
    } else {
        fnv.byte(0);
    }
}

template <typename Integer>
inline void optional_integer_feed(harness::Fnv& fnv, const std::optional<Integer>& value) {
    if (value) {
        fnv.byte(1);
        fnv.integer(static_cast<std::uint64_t>(static_cast<std::int64_t>(*value)));
    } else {
        fnv.byte(0);
    }
}

inline void indices_feed(harness::Fnv& fnv, const std::vector<std::uint32_t>& indices) {
    fnv.integer(indices.size());

    for (auto index : indices) {
        fnv.integer(index);
    }
}

template <typename Text>
inline void entities_feed(harness::Fnv& fnv, const EntitiesT<Text>& entities) {
    fnv.integer(entities.hashtags.size());

    for (const auto& hashtag : entities.hashtags) {
        fnv.text(hashtag.text);
        indices_feed(fnv, hashtag.indices);
    }

    fnv.integer(entities.user_mentions.size());

    for (const auto& mention : entities.user_mentions) {
        fnv.text(mention.screen_name);
        fnv.text(mention.name);
        fnv.integer(mention.id);
        indices_feed(fnv, mention.indices);
    }

    fnv.integer(entities.urls.size());

    for (const auto& url : entities.urls) {
        fnv.text(url.url);
        fnv.text(url.expanded_url);
        fnv.text(url.display_url);
        indices_feed(fnv, url.indices);
    }
}

template <typename Text>
inline void user_feed(harness::Fnv& fnv, const UserT<Text>& user) {
    fnv.integer(user.id);
    fnv.text(user.id_str);
    fnv.text(user.name);
    fnv.text(user.screen_name);
    fnv.text(user.location);
    fnv.text(user.description);
    optional_text_feed(fnv, user.url);
    fnv.integer(user.followers_count);
    fnv.integer(user.friends_count);
    fnv.integer(user.listed_count);
    fnv.text(user.created_at);
    fnv.integer(user.favourites_count);
    optional_integer_feed(fnv, user.utc_offset);
    optional_text_feed(fnv, user.time_zone);
    fnv.boolean(user.geo_enabled);
    fnv.boolean(user.verified);
    fnv.integer(user.statuses_count);
    fnv.text(user.lang);
    fnv.boolean(user.protected_);
}

template <typename Text>
inline void twitter_feed(harness::Fnv& fnv, const TwitterT<Text>& twitter) {
    fnv.integer(twitter.statuses.size());

    for (const auto& status : twitter.statuses) {
        fnv.text(status.created_at);
        fnv.integer(status.id);
        fnv.text(status.id_str);
        fnv.text(status.text);
        fnv.text(status.source);
        fnv.boolean(status.truncated);
        optional_integer_feed(fnv, status.in_reply_to_status_id);
        optional_integer_feed(fnv, status.in_reply_to_user_id);
        optional_text_feed(fnv, status.in_reply_to_screen_name);
        user_feed(fnv, status.user);
        fnv.integer(status.retweet_count);
        fnv.integer(status.favorite_count);
        fnv.boolean(status.favorited);
        fnv.boolean(status.retweeted);
        fnv.text(status.lang);
        entities_feed(fnv, status.entities);
    }

    const auto& metadata = twitter.search_metadata;

    fnv.integer(std::bit_cast<std::uint64_t>(metadata.completed_in));
    fnv.integer(metadata.max_id);
    fnv.text(metadata.max_id_str);
    fnv.text(metadata.next_results);
    fnv.text(metadata.query);
    fnv.text(metadata.refresh_url);
    fnv.integer(metadata.count);
    fnv.integer(metadata.since_id);
    fnv.text(metadata.since_id_str);
}
