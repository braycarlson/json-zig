use std::borrow::Cow;

use serde::{Deserialize, Serialize};

use crate::harness::Fnv;

#[derive(Debug, Deserialize, Serialize)]
pub struct Canada<'a> {
    #[serde(borrow)]
    pub r#type: Text<'a>,
    #[serde(borrow)]
    pub features: Vec<Feature<'a>>,
}

#[derive(Debug, Deserialize, Serialize)]
pub struct Entities<'a> {
    #[serde(borrow)]
    pub hashtags: Vec<Hashtag<'a>>,
    #[serde(borrow)]
    pub urls: Vec<Link<'a>>,
    #[serde(borrow)]
    pub user_mentions: Vec<Mention<'a>>,
}

#[derive(Debug, Deserialize, Serialize)]
pub struct Feature<'a> {
    #[serde(borrow)]
    pub r#type: Text<'a>,
    #[serde(borrow)]
    pub properties: Properties<'a>,
    #[serde(borrow)]
    pub geometry: Geometry<'a>,
}

#[derive(Debug, Deserialize, Serialize)]
pub struct Geometry<'a> {
    #[serde(borrow)]
    pub r#type: Text<'a>,
    pub coordinates: Vec<Vec<[f64; 2]>>,
}

#[derive(Debug, Deserialize, Serialize)]
pub struct Hashtag<'a> {
    #[serde(borrow)]
    pub text: Text<'a>,
    pub indices: Vec<u32>,
}

#[derive(Debug, Deserialize, Serialize)]
pub struct Link<'a> {
    #[serde(borrow)]
    pub url: Text<'a>,
    #[serde(borrow)]
    pub expanded_url: Text<'a>,
    #[serde(borrow)]
    pub display_url: Text<'a>,
    pub indices: Vec<u32>,
}

#[derive(Debug, Deserialize, Serialize)]
pub struct Mention<'a> {
    #[serde(borrow)]
    pub screen_name: Text<'a>,
    #[serde(borrow)]
    pub name: Text<'a>,
    pub id: u64,
    pub indices: Vec<u32>,
}

#[derive(Debug, Deserialize, Serialize)]
pub struct Properties<'a> {
    #[serde(borrow)]
    pub name: Text<'a>,
}

#[derive(Debug, Deserialize, Serialize)]
pub struct SearchMetadata<'a> {
    pub completed_in: f64,
    pub max_id: u64,
    #[serde(borrow)]
    pub max_id_str: Text<'a>,
    #[serde(borrow)]
    pub next_results: Text<'a>,
    #[serde(borrow)]
    pub query: Text<'a>,
    #[serde(borrow)]
    pub refresh_url: Text<'a>,
    pub count: u64,
    pub since_id: u64,
    #[serde(borrow)]
    pub since_id_str: Text<'a>,
}

#[derive(Debug, Deserialize, Serialize)]
pub struct Status<'a> {
    #[serde(borrow)]
    pub created_at: Text<'a>,
    pub id: u64,
    #[serde(borrow)]
    pub id_str: Text<'a>,
    #[serde(borrow)]
    pub text: Text<'a>,
    #[serde(borrow)]
    pub source: Text<'a>,
    pub truncated: bool,
    pub in_reply_to_status_id: Option<u64>,
    pub in_reply_to_user_id: Option<u64>,
    #[serde(borrow)]
    pub in_reply_to_screen_name: Option<Text<'a>>,
    #[serde(borrow)]
    pub user: User<'a>,
    pub retweet_count: u64,
    pub favorite_count: u64,
    #[serde(borrow)]
    pub entities: Entities<'a>,
    pub favorited: bool,
    pub retweeted: bool,
    #[serde(borrow)]
    pub lang: Text<'a>,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(transparent)]
pub struct Text<'a>(#[serde(borrow)] pub Cow<'a, str>);

#[derive(Debug, Deserialize, Serialize)]
pub struct Twitter<'a> {
    #[serde(borrow)]
    pub statuses: Vec<Status<'a>>,
    #[serde(borrow)]
    pub search_metadata: SearchMetadata<'a>,
}

#[derive(Debug, Deserialize, Serialize)]
pub struct User<'a> {
    pub id: u64,
    #[serde(borrow)]
    pub id_str: Text<'a>,
    #[serde(borrow)]
    pub name: Text<'a>,
    #[serde(borrow)]
    pub screen_name: Text<'a>,
    #[serde(borrow)]
    pub location: Text<'a>,
    #[serde(borrow)]
    pub description: Text<'a>,
    #[serde(borrow)]
    pub url: Option<Text<'a>>,
    pub protected: bool,
    pub followers_count: u64,
    pub friends_count: u64,
    pub listed_count: u64,
    #[serde(borrow)]
    pub created_at: Text<'a>,
    pub favourites_count: u64,
    pub utc_offset: Option<i64>,
    #[serde(borrow)]
    pub time_zone: Option<Text<'a>>,
    pub geo_enabled: bool,
    pub verified: bool,
    pub statuses_count: u64,
    #[serde(borrow)]
    pub lang: Text<'a>,
}

pub fn canada_checksum(canada: &Canada) -> String {
    assert!(u32::try_from(canada.features.len()).is_ok());

    let mut fnv = Fnv::INITIAL;

    fnv.text(&canada.r#type.0);
    fnv.integer(canada.features.len() as u64);

    for feature in &canada.features {
        fnv.text(&feature.r#type.0);
        fnv.text(&feature.properties.name.0);
        fnv.text(&feature.geometry.r#type.0);
        fnv.integer(feature.geometry.coordinates.len() as u64);

        for ring in &feature.geometry.coordinates {
            fnv.integer(ring.len() as u64);

            for point in ring {
                fnv.integer(point[0].to_bits());
                fnv.integer(point[1].to_bits());
            }
        }
    }

    assert_ne!(fnv.state, Fnv::INITIAL.state);

    fnv.hex()
}

pub fn twitter_checksum(twitter: &Twitter) -> String {
    assert!(u32::try_from(twitter.statuses.len()).is_ok());

    let mut fnv = Fnv::INITIAL;
    let metadata = &twitter.search_metadata;

    fnv.integer(twitter.statuses.len() as u64);

    for status in &twitter.statuses {
        status_feed(&mut fnv, status);
    }

    fnv.integer(metadata.completed_in.to_bits());
    fnv.integer(metadata.max_id);
    fnv.text(&metadata.max_id_str.0);
    fnv.text(&metadata.next_results.0);
    fnv.text(&metadata.query.0);
    fnv.text(&metadata.refresh_url.0);
    fnv.integer(metadata.count);
    fnv.integer(metadata.since_id);
    fnv.text(&metadata.since_id_str.0);

    assert_ne!(fnv.state, Fnv::INITIAL.state);

    fnv.hex()
}

fn entities_feed(fnv: &mut Fnv, entities: &Entities) {
    assert!(u32::try_from(entities.hashtags.len()).is_ok());
    assert!(u32::try_from(entities.urls.len()).is_ok());
    assert!(u32::try_from(entities.user_mentions.len()).is_ok());

    fnv.integer(entities.hashtags.len() as u64);

    for hashtag in &entities.hashtags {
        fnv.text(&hashtag.text.0);
        indices_feed(fnv, &hashtag.indices);
    }

    fnv.integer(entities.user_mentions.len() as u64);

    for mention in &entities.user_mentions {
        fnv.text(&mention.screen_name.0);
        fnv.text(&mention.name.0);
        fnv.integer(mention.id);
        indices_feed(fnv, &mention.indices);
    }

    fnv.integer(entities.urls.len() as u64);

    for link in &entities.urls {
        fnv.text(&link.url.0);
        fnv.text(&link.expanded_url.0);
        fnv.text(&link.display_url.0);
        indices_feed(fnv, &link.indices);
    }
}

fn indices_feed(fnv: &mut Fnv, indices: &[u32]) {
    assert!(u32::try_from(indices.len()).is_ok());

    fnv.integer(indices.len() as u64);

    for index in indices {
        fnv.integer(u64::from(*index));
    }
}

fn optional_integer_feed<Integer: Copy + Into<i128>>(fnv: &mut Fnv, value: Option<Integer>) {
    assert!(value.is_none_or(|integer| i64::try_from(integer.into()).is_ok()));

    fnv.boolean(value.is_some());

    if let Some(integer) = value {
        let signed = i64::try_from(integer.into()).expect("the integer fits in i64");

        fnv.integer(signed.cast_unsigned());
    }
}

fn optional_text_feed(fnv: &mut Fnv, value: Option<&Text>) {
    assert!(value.is_none_or(|text| u32::try_from(text.0.len()).is_ok()));

    fnv.boolean(value.is_some());

    if let Some(text) = value {
        fnv.text(&text.0);
    }
}

fn status_feed(fnv: &mut Fnv, status: &Status) {
    assert!(u32::try_from(status.entities.hashtags.len()).is_ok());
    assert!(u32::try_from(status.entities.urls.len()).is_ok());
    assert!(u32::try_from(status.text.0.len()).is_ok());

    fnv.text(&status.created_at.0);
    fnv.integer(status.id);
    fnv.text(&status.id_str.0);
    fnv.text(&status.text.0);
    fnv.text(&status.source.0);
    fnv.boolean(status.truncated);
    optional_integer_feed(fnv, status.in_reply_to_status_id);
    optional_integer_feed(fnv, status.in_reply_to_user_id);
    optional_text_feed(fnv, status.in_reply_to_screen_name.as_ref());
    user_feed(fnv, &status.user);
    fnv.integer(status.retweet_count);
    fnv.integer(status.favorite_count);
    fnv.boolean(status.favorited);
    fnv.boolean(status.retweeted);
    fnv.text(&status.lang.0);
    entities_feed(fnv, &status.entities);
}

fn user_feed(fnv: &mut Fnv, user: &User) {
    assert!(u32::try_from(user.name.0.len()).is_ok());
    assert!(u32::try_from(user.description.0.len()).is_ok());
    assert!(u32::try_from(user.screen_name.0.len()).is_ok());

    fnv.integer(user.id);
    fnv.text(&user.id_str.0);
    fnv.text(&user.name.0);
    fnv.text(&user.screen_name.0);
    fnv.text(&user.location.0);
    fnv.text(&user.description.0);
    optional_text_feed(fnv, user.url.as_ref());
    fnv.integer(user.followers_count);
    fnv.integer(user.friends_count);
    fnv.integer(user.listed_count);
    fnv.text(&user.created_at.0);
    fnv.integer(user.favourites_count);
    optional_integer_feed(fnv, user.utc_offset);
    optional_text_feed(fnv, user.time_zone.as_ref());
    fnv.boolean(user.geo_enabled);
    fnv.boolean(user.verified);
    fnv.integer(user.statuses_count);
    fnv.text(&user.lang.0);
    fnv.boolean(user.protected);
}
