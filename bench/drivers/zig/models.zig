const std = @import("std");

const harness = @import("harness.zig");

const assert = std.debug.assert;

const Fnv = harness.Fnv;

pub const Canada = struct {
    type: []const u8 = "",
    features: []const Feature = &.{},
};

pub const Entities = struct {
    hashtags: []const Hashtag = &.{},
    urls: []const Link = &.{},
    user_mentions: []const Mention = &.{},
};

pub const Feature = struct {
    type: []const u8 = "",
    properties: Properties = .{},
    geometry: Geometry = .{},
};

pub const Geometry = struct {
    type: []const u8 = "",
    coordinates: []const []const [2]f64 = &.{},
};

pub const Hashtag = struct {
    text: []const u8 = "",
    indices: []const u32 = &.{},
};

pub const Link = struct {
    url: []const u8 = "",
    expanded_url: []const u8 = "",
    display_url: []const u8 = "",
    indices: []const u32 = &.{},
};

pub const Mention = struct {
    screen_name: []const u8 = "",
    name: []const u8 = "",
    id: u64 = 0,
    indices: []const u32 = &.{},
};

pub const Properties = struct {
    name: []const u8 = "",
};

pub const SearchMetadata = struct {
    completed_in: f64 = 0,
    max_id: u64 = 0,
    max_id_str: []const u8 = "",
    next_results: []const u8 = "",
    query: []const u8 = "",
    refresh_url: []const u8 = "",
    count: u64 = 0,
    since_id: u64 = 0,
    since_id_str: []const u8 = "",
};

pub const Status = struct {
    created_at: []const u8 = "",
    id: u64 = 0,
    id_str: []const u8 = "",
    text: []const u8 = "",
    source: []const u8 = "",
    truncated: bool = false,
    in_reply_to_status_id: ?u64 = null,
    in_reply_to_user_id: ?u64 = null,
    in_reply_to_screen_name: ?[]const u8 = null,
    user: User = .{},
    retweet_count: u64 = 0,
    favorite_count: u64 = 0,
    entities: Entities = .{},
    favorited: bool = false,
    retweeted: bool = false,
    lang: []const u8 = "",
};

pub const Twitter = struct {
    statuses: []const Status = &.{},
    search_metadata: SearchMetadata = .{},
};

pub const User = struct {
    id: u64 = 0,
    id_str: []const u8 = "",
    name: []const u8 = "",
    screen_name: []const u8 = "",
    location: []const u8 = "",
    description: []const u8 = "",
    url: ?[]const u8 = null,
    protected: bool = false,
    followers_count: u64 = 0,
    friends_count: u64 = 0,
    listed_count: u64 = 0,
    created_at: []const u8 = "",
    favourites_count: u64 = 0,
    utc_offset: ?i64 = null,
    time_zone: ?[]const u8 = null,
    geo_enabled: bool = false,
    verified: bool = false,
    statuses_count: u64 = 0,
    lang: []const u8 = "",
};

pub fn canada_feed(fnv: *Fnv, canada: *const Canada) void {
    assert(canada.features.len < std.math.maxInt(u32));

    fnv.text(canada.type);
    fnv.integer(canada.features.len);

    for (canada.features) |*feature| {
        fnv.text(feature.type);
        fnv.text(feature.properties.name);
        fnv.text(feature.geometry.type);
        fnv.integer(feature.geometry.coordinates.len);

        for (feature.geometry.coordinates) |ring| {
            fnv.integer(ring.len);

            for (ring) |point| {
                fnv.integer(@bitCast(point[0]));
                fnv.integer(@bitCast(point[1]));
            }
        }
    }

    assert(fnv.state != 0);
}

pub fn twitter_feed(fnv: *Fnv, twitter: *const Twitter) void {
    assert(twitter.statuses.len < std.math.maxInt(u32));

    fnv.integer(twitter.statuses.len);

    for (twitter.statuses) |*status| {
        status_feed(fnv, status);
    }

    const metadata = &twitter.search_metadata;

    fnv.integer(@bitCast(metadata.completed_in));
    fnv.integer(metadata.max_id);
    fnv.text(metadata.max_id_str);
    fnv.text(metadata.next_results);
    fnv.text(metadata.query);
    fnv.text(metadata.refresh_url);
    fnv.integer(metadata.count);
    fnv.integer(metadata.since_id);
    fnv.text(metadata.since_id_str);

    assert(fnv.state != 0);
}

fn status_feed(fnv: *Fnv, status: *const Status) void {
    assert(status.entities.hashtags.len < std.math.maxInt(u32));
    assert(status.entities.urls.len < std.math.maxInt(u32));
    assert(status.text.len < std.math.maxInt(u32));

    fnv.text(status.created_at);
    fnv.integer(status.id);
    fnv.text(status.id_str);
    fnv.text(status.text);
    fnv.text(status.source);
    fnv.boolean(status.truncated);
    optional_integer_feed(fnv, status.in_reply_to_status_id);
    optional_integer_feed(fnv, status.in_reply_to_user_id);
    optional_text_feed(fnv, status.in_reply_to_screen_name);
    user_feed(fnv, &status.user);
    fnv.integer(status.retweet_count);
    fnv.integer(status.favorite_count);
    fnv.boolean(status.favorited);
    fnv.boolean(status.retweeted);
    fnv.text(status.lang);
    entities_feed(fnv, &status.entities);
}

fn entities_feed(fnv: *Fnv, entities: *const Entities) void {
    assert(entities.hashtags.len < std.math.maxInt(u32));
    assert(entities.user_mentions.len < std.math.maxInt(u32));

    fnv.integer(entities.hashtags.len);

    for (entities.hashtags) |hashtag| {
        fnv.text(hashtag.text);
        indices_feed(fnv, hashtag.indices);
    }

    fnv.integer(entities.user_mentions.len);

    for (entities.user_mentions) |mention| {
        fnv.text(mention.screen_name);
        fnv.text(mention.name);
        fnv.integer(mention.id);
        indices_feed(fnv, mention.indices);
    }

    fnv.integer(entities.urls.len);

    for (entities.urls) |link| {
        fnv.text(link.url);
        fnv.text(link.expanded_url);
        fnv.text(link.display_url);
        indices_feed(fnv, link.indices);
    }
}

fn indices_feed(fnv: *Fnv, indices: []const u32) void {
    assert(indices.len < std.math.maxInt(u32));

    fnv.integer(indices.len);

    for (indices) |index| fnv.integer(index);
}

fn optional_integer_feed(fnv: *Fnv, value: anytype) void {
    comptime assert(@typeInfo(@TypeOf(value)) == .optional);
    if (value) |number| assert(number <= std.math.maxInt(i64));

    if (value) |number| {
        fnv.byte(1);
        fnv.integer(@bitCast(@as(i64, @intCast(number))));
    } else {
        fnv.byte(0);
    }
}

fn optional_text_feed(fnv: *Fnv, value: ?[]const u8) void {
    if (value) |text| assert(text.len < std.math.maxInt(u32));

    if (value) |text| {
        fnv.byte(1);
        fnv.text(text);
    } else {
        fnv.byte(0);
    }
}

fn user_feed(fnv: *Fnv, user: *const User) void {
    assert(user.name.len < std.math.maxInt(u32));
    assert(user.description.len < std.math.maxInt(u32));
    assert(user.screen_name.len < std.math.maxInt(u32));

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
    fnv.boolean(user.protected);
}
