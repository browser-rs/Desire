//! website/demo 演示页的后端：公开路由（不过 JWT）。
//! CORS 在 routes/mod.rs 里单独加——演示页跨源调本服务。

use axum::Router;
use axum::routing::{delete, get, post};

use crate::modules::demo::demo_controller;
use crate::types::AppState;

pub fn router() -> Router<AppState> {
  Router::new()
    .route("/demo/products", get(demo_controller::products))
    .route("/demo/cart", get(demo_controller::cart_get))
    .route("/demo/cart/items", post(demo_controller::cart_add))
    .route(
      "/demo/cart/items/{sku}",
      delete(demo_controller::cart_remove),
    )
    .route("/demo/orders", post(demo_controller::checkout))
    .route("/demo/orders", get(demo_controller::orders_get))
    .route("/demo/im/channels", get(demo_controller::im_channels))
    .route(
      "/demo/im/messages",
      get(demo_controller::im_messages).post(demo_controller::im_send),
    )
    .route("/demo/im/ws", get(demo_controller::im_ws))
    .route("/demo/forum/posts", get(demo_controller::forum_posts))
    .route("/demo/forum/posts", post(demo_controller::forum_create))
    .route(
      "/demo/forum/posts/{id}/like",
      post(demo_controller::forum_like),
    )
    .route(
      "/demo/forum/posts/{id}/comments",
      get(demo_controller::forum_comments),
    )
    .route(
      "/demo/forum/posts/{id}/comments",
      post(demo_controller::forum_comment),
    )
}
