//! 桥接层入口（FRB 扫描 `crate::api` 下全部内容）。

pub mod dto;
pub mod error;
pub mod weibo;

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
    install_panic_logger();
}

/// 把 Rust panic 送到 Android logcat / stdout。
///
/// # 为什么需要这个
///
/// panic 默认只写 stderr，而 Android 应用的 stderr 被丢弃 —— 于是 release 包里
/// 出了 panic，只能看到一个没有信息量的上层报错。这次排查就吃了这个亏：
/// FRB 只报出 `PanicException(event loop thread panicked)`，
/// 而真正的 panic 原因（在 reqwest 的内部事件循环线程里）完全看不到。
///
/// 装上 hook 后，logcat 里能直接看到 `RUST PANIC: ...` 与位置。
fn install_panic_logger() {
    use std::sync::Once;
    static ONCE: Once = Once::new();
    ONCE.call_once(|| {
        let default_hook = std::panic::take_hook();
        std::panic::set_hook(Box::new(move |info| {
            let msg = format!("RUST PANIC: {info}");
            eprintln!("{msg}");
            #[cfg(target_os = "android")]
            {
                // 6 = ANDROID_LOG_ERROR
                let tag = c"weibo_rust";
                if let Ok(cmsg) = std::ffi::CString::new(msg.clone()) {
                    unsafe {
                        __android_log_write(6, tag.as_ptr(), cmsg.as_ptr());
                    }
                }
            }
            default_hook(info);
        }));
    });
}

#[cfg(target_os = "android")]
unsafe extern "C" {
    fn __android_log_write(prio: i32, tag: *const std::os::raw::c_char, text: *const std::os::raw::c_char) -> i32;
}
