//! 兼容渲染的逐像素透明：独立的分层显示窗口（`UpdateLayeredWindow`）。
//!
//! 兼容后端（Direct3D 12 交换链、部分 AMD OpenGL 驱动）交给系统的画面没有可用的 alpha，
//! 透明画布会显示成黑块，过去只能按岛体轮廓裁剪窗口区域；窗口区域逐像素「要么有要么没有」，
//! 圆角和肩部必然出现锯齿。
//!
//! 现在的做法：
//! - 画面变化时把渲染结果读回（已预乘 alpha），交给一个只负责显示的分层窗口，
//!   它紧贴在岛仔窗口正上方、鼠标一律穿透，边缘保留抗锯齿；
//! - 岛仔窗口本身设成整体不透明度 1/255 的分层窗口：交换链的画面几乎完全看不见，
//!   但仍按原来的窗口区域与命中区接收点击、悬停和拖放（不透明度为 0 时系统不再命中）。
//!   直接对岛仔窗口用 `UpdateLayeredWindow` 不行：翻转模型交换链的画面会盖过分层内容。

use windows::Win32::Foundation::{COLORREF, HWND, LPARAM, LRESULT, POINT, RECT, SIZE, WPARAM};
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::UI::WindowsAndMessaging::*;

/// 岛仔窗口的整体不透明度：1/255 仍可命中，交换链画面肉眼不可见。
const OWNER_ALPHA: u8 = 1;

/// 读回画面的哈希：画面没变时不必重设分层窗口，也不再请求下一次读回。
pub fn image_hash(size: [usize; 2], rgba: &[u8]) -> u64 {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325 ^ ((size[0] as u64) << 32 | size[1] as u64);
    for p in rgba.chunks_exact(8) {
        h = (h ^ u64::from_le_bytes(p.try_into().unwrap())).wrapping_mul(0x0000_0100_0000_01b3);
    }
    h
}

/// 读回的画面里必须真的有透明像素（画布四角一定是透明的），否则说明这条路径读不到 alpha，
/// 不能切到分层窗口（整块画布会变成黑底）。
pub fn has_real_alpha(size: [usize; 2], rgba: &[u8]) -> bool {
    let [w, h] = size;
    if w == 0 || h == 0 || rgba.len() != w * h * 4 { return false; }
    let corner = |x: usize, y: usize| rgba[(y * w + x) * 4 + 3];
    [corner(0, 0), corner(w - 1, 0), corner(0, h - 1), corner(w - 1, h - 1)].iter().any(|&a| a < 255)
}

/// 显示窗口：鼠标一律穿透、不激活。
unsafe extern "system" fn display_proc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    match msg {
        WM_NCHITTEST => LRESULT(HTTRANSPARENT as isize),
        WM_MOUSEACTIVATE => LRESULT(MA_NOACTIVATE as isize),
        _ => DefWindowProcW(hwnd, msg, wp, lp),
    }
}

fn create_display_window() -> windows::core::Result<HWND> {
    use windows::Win32::System::LibraryLoader::GetModuleHandleW;
    static CLASS: std::sync::Once = std::sync::Once::new();
    let instance = unsafe { GetModuleHandleW(None)? };
    let class = windows::core::w!("DaozaiLayeredDisplay");
    CLASS.call_once(|| unsafe {
        let wc = WNDCLASSW { lpfnWndProc: Some(display_proc), hInstance: instance.into(), lpszClassName: class, ..Default::default() };
        RegisterClassW(&wc);
    });
    unsafe {
        CreateWindowExW(
            WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_TOPMOST,
            class,
            windows::core::w!(""),
            WS_POPUP,
            0, 0, 1, 1,
            None, None, instance, None,
        )
    }
}

/// 让岛仔窗口自身几乎不可见但仍可命中；winit 改样式时可能抹掉分层位，每帧兜底。
unsafe fn hide_owner(owner: HWND) -> windows::core::Result<()> {
    let ex = GetWindowLongPtrW(owner, GWL_EXSTYLE);
    if ex & WS_EX_LAYERED.0 as isize == 0 {
        SetWindowLongPtrW(owner, GWL_EXSTYLE, ex | WS_EX_LAYERED.0 as isize);
        SetLayeredWindowAttributes(owner, COLORREF(0), OWNER_ALPHA, LWA_ALPHA)?;
    }
    Ok(())
}

/// 层级上紧挨在下面的可见窗口（跳过输入法等隐藏的辅助窗口）。
unsafe fn next_visible(hwnd: HWND) -> Option<HWND> {
    let mut current = hwnd;
    while let Ok(next) = GetWindow(current, GW_HWNDNEXT) {
        if IsWindowVisible(next).as_bool() { return Some(next); }
        current = next;
    }
    None
}

pub struct Layered {
    display: HWND,
    dc: HDC,
    bitmap: HBITMAP,
    old: HGDIOBJ,
    bits: *mut u8,
    size: (i32, i32),
    last: Option<u64>,
}

impl Layered {
    pub fn new() -> windows::core::Result<Self> {
        let display = create_display_window()?;
        let dc = unsafe { CreateCompatibleDC(None) };
        if dc.is_invalid() {
            unsafe { let _ = DestroyWindow(display); }
            return Err(windows::core::Error::from_win32());
        }
        Ok(Self { display, dc, bitmap: HBITMAP::default(), old: HGDIOBJ::default(), bits: std::ptr::null_mut(), size: (0, 0), last: None })
    }

    #[cfg(test)]
    pub fn display(&self) -> HWND { self.display }

    fn ensure_bitmap(&mut self, w: i32, h: i32) -> bool {
        if self.size == (w, h) && !self.bits.is_null() { return true; }
        unsafe {
            self.release_bitmap();
            let info = BITMAPINFO {
                bmiHeader: BITMAPINFOHEADER {
                    biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
                    biWidth: w,
                    biHeight: -h, // 自上而下
                    biPlanes: 1,
                    biBitCount: 32,
                    biCompression: BI_RGB.0,
                    ..Default::default()
                },
                ..Default::default()
            };
            let mut bits = std::ptr::null_mut();
            let Ok(bitmap) = CreateDIBSection(self.dc, &info, DIB_RGB_COLORS, &mut bits, None, 0) else { return false };
            if bits.is_null() { let _ = DeleteObject(bitmap); return false; }
            self.old = SelectObject(self.dc, bitmap);
            self.bitmap = bitmap;
            self.bits = bits.cast();
            self.size = (w, h);
        }
        true
    }

    unsafe fn release_bitmap(&mut self) {
        if !self.bitmap.is_invalid() {
            SelectObject(self.dc, self.old);
            let _ = DeleteObject(self.bitmap);
        }
        self.bitmap = HBITMAP::default();
        self.bits = std::ptr::null_mut();
        self.size = (0, 0);
    }

    /// 把一帧（RGBA，已预乘）交给显示窗口。画面没变返回 Ok(false)；
    /// 尺寸与岛仔窗口当前大小不符（读回之后窗口又改了大小）时跳过，等下一帧。
    pub fn present(&mut self, owner: HWND, size: [usize; 2], rgba: &[u8]) -> windows::core::Result<bool> {
        let (w, h) = (size[0] as i32, size[1] as i32);
        let mut rect = RECT::default();
        unsafe { GetWindowRect(owner, &mut rect)?; }
        if (rect.right - rect.left, rect.bottom - rect.top) != (w, h) || rgba.len() != size[0] * size[1] * 4 { return Ok(false); }
        let hash = image_hash(size, rgba);
        if self.last == Some(hash) { return Ok(false); }
        if !self.ensure_bitmap(w, h) { return Err(windows::core::Error::from_win32()); }
        unsafe {
            let dst = std::slice::from_raw_parts_mut(self.bits, rgba.len());
            for (out, p) in dst.chunks_exact_mut(4).zip(rgba.chunks_exact(4)) {
                out[0] = p[2]; out[1] = p[1]; out[2] = p[0]; out[3] = p[3];
            }
            let _ = GdiFlush();
            let blend = BLENDFUNCTION { BlendOp: AC_SRC_OVER as u8, BlendFlags: 0, SourceConstantAlpha: 255, AlphaFormat: AC_SRC_ALPHA as u8 };
            let (src, dst_pos, sz) = (POINT::default(), POINT { x: rect.left, y: rect.top }, SIZE { cx: w, cy: h });
            UpdateLayeredWindow(self.display, None, Some(&dst_pos), Some(&sz), self.dc, Some(&src), COLORREF(0), Some(&blend), ULW_ALPHA)?;
            // 显示窗口有了内容之后才把岛仔窗口自身藏起来，避免切换瞬间什么都看不到。
            hide_owner(owner)?;
        }
        self.last = Some(hash);
        self.sync(owner, false);
        Ok(true)
    }

    /// 每帧跟随岛仔窗口：可见性、位置，以及紧贴在它正上方的层级。
    pub fn sync(&mut self, owner: HWND, raise: bool) {
        if self.last.is_none() { return; }
        unsafe {
            let _ = hide_owner(owner);
            let owner_visible = IsWindowVisible(owner).as_bool();
            let display_visible = IsWindowVisible(self.display).as_bool();
            if !owner_visible {
                if display_visible { let _ = ShowWindow(self.display, SW_HIDE); }
                return;
            }
            let (mut o, mut d) = (RECT::default(), RECT::default());
            if GetWindowRect(owner, &mut o).is_err() || GetWindowRect(self.display, &mut d).is_err() { return; }
            let flags = SWP_NOACTIVATE | SWP_NOSIZE;
            if (o.left, o.top) != (d.left, d.top) || !display_visible || raise {
                let _ = SetWindowPos(self.display, HWND_TOPMOST, o.left, o.top, 0, 0, flags | SWP_SHOWWINDOW);
            }
            // 岛仔窗口紧贴在显示窗口下面：别的置顶窗口不会夹在两者之间。
            if next_visible(self.display) != Some(owner) {
                let _ = SetWindowPos(owner, self.display, 0, 0, 0, 0, flags | SWP_NOMOVE);
            }
        }
    }

    /// 放弃分层显示，岛仔窗口恢复为普通窗口（回到轮廓裁剪）。
    pub fn detach(&mut self, owner: HWND) {
        unsafe {
            let ex = GetWindowLongPtrW(owner, GWL_EXSTYLE);
            if ex & WS_EX_LAYERED.0 as isize != 0 { SetWindowLongPtrW(owner, GWL_EXSTYLE, ex & !(WS_EX_LAYERED.0 as isize)); }
            let _ = ShowWindow(self.display, SW_HIDE);
        }
        self.last = None;
    }
}

impl Drop for Layered {
    fn drop(&mut self) {
        unsafe {
            self.release_bitmap();
            let _ = DeleteDC(self.dc);
            let _ = DestroyWindow(self.display);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn opaque_readback_is_not_trusted_for_layering() {
        let opaque = [0u8, 0, 0, 255].repeat(16);
        assert!(!has_real_alpha([4, 4], &opaque), "读不到 alpha 时不能切到分层窗口");
        let mut clear = opaque.clone();
        clear[3] = 0;
        assert!(has_real_alpha([4, 4], &clear));
        assert!(!has_real_alpha([4, 4], &clear[..32]), "尺寸不符视为无效");
    }

    #[test]
    fn hash_changes_with_content_and_size() {
        let a = [1u8, 2, 3, 4].repeat(6);
        let mut b = a.clone();
        b[23] = 5;
        assert_ne!(image_hash([3, 2], &a), image_hash([3, 2], &b));
        assert_ne!(image_hash([3, 2], &a), image_hash([2, 3], &a));
        assert_eq!(image_hash([3, 2], &a), image_hash([3, 2], &a));
    }

    /// 兼容渲染每帧都会走这里：连续提交几千帧不同画面，进程内存和 GDI 对象都不能随帧数增长。
    #[test]
    fn presenting_many_frames_does_not_leak() {
        unsafe {
            use windows::Win32::System::Threading::{GetCurrentProcess, GetGuiResources, GR_GDIOBJECTS, GR_USEROBJECTS};
            let (w, h) = (960usize, 285usize);
            let owner = CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE, windows::core::w!("BUTTON"), windows::core::w!(""), WS_POPUP | WS_VISIBLE, -10000, -10000, w as i32, h as i32, None, None, None, None).unwrap();
            let mut layered = Layered::new().unwrap();
            let mut frame = vec![0u8; w * h * 4];
            let mut present = |n: u32, layered: &mut Layered| for i in 0..n {
                frame[(i as usize * 4) % (w * h * 4)] = (i % 251) as u8;
                frame[3] = (i % 200) as u8;
                assert!(layered.present(owner, [w, h], &frame).unwrap(), "每帧画面不同，必须真正提交");
            };
            present(300, &mut layered);
            let gdi = |kind| GetGuiResources(GetCurrentProcess(), kind);
            let (mem0, gdi0, user0) = (crate::resources::snapshot().unwrap().private_bytes, gdi(GR_GDIOBJECTS), gdi(GR_USEROBJECTS));
            present(3000, &mut layered);
            let (mem1, gdi1, user1) = (crate::resources::snapshot().unwrap().private_bytes, gdi(GR_GDIOBJECTS), gdi(GR_USEROBJECTS));
            eprintln!("3000 帧：私有内存 {:+.1} MB，GDI {gdi0}→{gdi1}，USER {user0}→{user1}", (mem1 as f64 - mem0 as f64) / 1048576.0);
            assert!(mem1 < mem0 + 8 * 1024 * 1024, "3000 帧后私有内存增长超过 8MB");
            assert!(gdi1 <= gdi0 + 2 && user1 <= user0 + 2, "GDI/USER 对象随帧数增长");
            drop(layered);
            let _ = DestroyWindow(owner);
        }
    }

    #[test]
    fn display_window_follows_owner_and_owner_stays_clickable() {
        unsafe {
            // 用 BUTTON：STATIC 自己就返回 HTTRANSPARENT，测不出命中。
            let owner = CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_TOPMOST, windows::core::w!("BUTTON"), windows::core::w!(""), WS_POPUP | WS_VISIBLE, -10000, -10000, 4, 2, None, None, None, None).unwrap();
            let mut layered = Layered::new().unwrap();
            let mut px = vec![0u8; 32];
            px[4..8].copy_from_slice(&[64, 64, 64, 128]);
            px[8..12].copy_from_slice(&[255, 255, 255, 255]);
            assert!(layered.present(owner, [4, 2], &px).unwrap());
            let mut alpha = 0u8;
            GetLayeredWindowAttributes(owner, None, Some(&mut alpha), None).unwrap();
            assert_eq!(alpha, OWNER_ALPHA, "岛仔窗口几乎不可见，但不能是 0（否则点不到）");
            assert!(IsWindowVisible(layered.display()).as_bool());
            assert_eq!(next_visible(layered.display()), Some(owner), "岛仔窗口紧贴在显示窗口下面");
            assert!(!layered.present(owner, [4, 2], &px).unwrap(), "同一画面不重复提交");
            assert!(!layered.present(owner, [8, 1], &[0u8; 32]).unwrap(), "尺寸与窗口不符时跳过");
            SetWindowPos(owner, None, -9000, -9000, 0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE).unwrap();
            layered.sync(owner, false);
            let mut d = RECT::default();
            GetWindowRect(layered.display(), &mut d).unwrap();
            assert_eq!((d.left, d.top), (-9000, -9000), "窗口移动后显示窗口跟随");
            let _ = ShowWindow(owner, SW_HIDE);
            layered.sync(owner, false);
            assert!(!IsWindowVisible(layered.display()).as_bool(), "岛仔窗口隐藏时显示窗口一起隐藏");
            layered.detach(owner);
            assert!(GetWindowLongPtrW(owner, GWL_EXSTYLE) & WS_EX_LAYERED.0 as isize == 0);
            let _ = DestroyWindow(owner);
        }
    }
}
