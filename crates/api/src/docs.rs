use axum::Json;
use utoipa::OpenApi;

#[derive(OpenApi)]
#[openapi(
  info(title = "Desire API", version = "0.0.1"),
  paths(
    crate::modules::auth::auth_controller::register,
    crate::modules::auth::auth_controller::login,
    crate::modules::auth::auth_controller::refresh,
    crate::modules::auth::auth_controller::logout,
    crate::modules::auth::auth_controller::me,
    crate::modules::auth::auth_controller::update_me,
    crate::modules::auth::auth_controller::set_password,
    crate::modules::auth::auth_controller::list_devices,
    crate::modules::auth::auth_controller::revoke_device,
    crate::modules::sync::sync_controller::pull,
    crate::modules::sync::sync_controller::push,
  ),
  components(schemas(
    crate::modules::auth::auth_model::RegisterReq,
    crate::modules::auth::auth_model::LoginReq,
    crate::modules::auth::auth_model::DeviceInfoReq,
    crate::modules::auth::auth_model::TokenPair,
    crate::modules::auth::auth_model::SetPasswordReq,
    crate::modules::auth::auth_model::UpdateProfileReq,
    crate::modules::auth::auth_model::MeDto,
    crate::modules::auth::auth_model::RevokeDeviceReq,
    crate::modules::auth::auth_model::DeviceDto,
    crate::modules::sync::sync_model::SyncPushReq,
    crate::modules::sync::sync_model::SyncPushItem,
    crate::modules::sync::sync_model::SyncItemDto,
    crate::modules::sync::sync_model::SyncPullResp,
    crate::modules::sync::sync_model::SyncPushResp,
    crate::modules::sync::sync_model::SyncPushResultItem,
  )),
  tags((name = "auth", description = "账号 / 设备 / 令牌"),
       (name = "sync", description = "跨设备同步(按域 push/pull)")),
)]
struct ApiDoc;

/// OpenAPI 契约仅 dev 暴露(routes/mod.rs 挂载时按 Env 判)。
/// 后续 Desire 客户端的模型/路由层可以从这份 spec 生成。
pub async fn openapi_json() -> Json<serde_json::Value> {
  Json(serde_json::to_value(ApiDoc::openapi()).unwrap_or(serde_json::Value::Null))
}
