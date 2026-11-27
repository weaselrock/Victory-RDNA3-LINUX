//! Renderer port 1, placed (`VICTORY_PORT_PLACED=1`, with
//! `VICTORY_PORT_CONSTANTS=1`; off by default): the title's 32-bit graphics
//! reservation backed by the card's own allocation, mapped by the driver at
//! the title's address.
//!
//! Port 1 ([`crate::port`]) opens the stretch of section views the title
//! maps there as a host heap from an address (`OpenExistingHeapFromAddress1`).
//! Under Wine that heap is imported host memory, which RADV makes an amdgpu
//! userptr: every protection change or unmapping in the process invalidates
//! it, and the frame rate falls apart.
//!
//! Here instead (`xmem` drives it, at the title's first mapping of physical
//! pages into the reservation): a D3D12 heap of the reservation's size is
//! made (custom, write-back, pool L0, buffers only), vkd3d-proton names its
//! `VkDeviceMemory` (`ID3D12DXVKInteropDevice3::GetVulkanHeapInfo`, which
//! must give offset 0: a whole allocation), vkd3d's own CPU mapping of it is
//! let go keeping its addresses reserved (`vkUnmapMemory2`, `RESERVE`), the
//! title's placeholders are committed read-write by `xmem`, and the memory
//! is mapped over them at the title's address (`vkMapMemory2`, `PLACED`).
//! The CPU and the card then share the pages; protection changes cost what
//! they cost on any memory. Port 1's buffers and windows there are placed in
//! that heap at their offsets, as before in the opened one.
//!
//! What it needs: `VK_KHR_map_memory2` and `VK_EXT_map_memory_placed` enabled
//! on vkd3d-proton's device, which the implicit layer
//! `VK_LAYER_VICTORY_placed` does (`ENABLE_VICTORY_PLACED=1`). Without it the
//! placed mapping fails or lands elsewhere: logged once, and port 1 goes on
//! as before.
//!
//! Never `Map()` a resource of such a heap: vkd3d's CPU address of it is the
//! reserved range it no longer has. Never write-watch the range (the
//! kernel's write protection faults fail on a driver mapping).

use std::ffi::c_void;
use std::sync::OnceLock;
use std::sync::atomic::{AtomicU64, Ordering};

use windows::Win32::Graphics::Direct3D12::*;
use windows::core::{GUID, HRESULT, Interface};

const K64: u64 = 64 << 10;

/// The most bytes of one placed heap.
const MOST: u64 = 4 << 30;

/// `VICTORY_PORT_PLACED`: `1` (with `VICTORY_PORT_CONSTANTS=1`) backs the
/// title's 32-bit graphics reservation with a placed mapping of the card's
/// allocation; unset or anything else: port 1 as before.
pub fn on() -> bool {
    static ON: OnceLock<bool> = OnceLock::new();
    // Read once, here: the switch of the placed form of renderer port 1.
    *ON.get_or_init(|| crate::port::on() && std::env::var("VICTORY_PORT_PLACED").is_ok_and(|v| v.trim() == "1"))
}

/// Since the start: heaps placed, their bytes, fallbacks (port 1's old path
/// kept), heaps let go again, their bytes, times port 1 was told to forget a
/// placed region (kept: only `xmem` lets it go).
static STATS: [AtomicU64; 6] = [const { AtomicU64::new(0) }; 6];

// vkd3d-proton's interop interface (vkd3d_device_vkd3d_ext.idl), as far as
// it is called here.
const IID_INTEROP3: GUID = GUID::from_u128(0x22a70184_a6a4_4c24_bf97_7d6df9f12d8a);

#[repr(C)]
struct InteropVtbl {
    query_interface: usize,
    add_ref: usize,
    release: unsafe extern "system" fn(*mut c_void) -> u32,
    get_dxgi_adapter: usize,
    get_instance_extensions: usize,
    get_device_extensions: usize,
    get_device_features: usize,
    get_vulkan_handles: unsafe extern "system" fn(*mut c_void, *mut u64, *mut u64, *mut u64) -> HRESULT,
    get_vulkan_queue_info: usize,
    get_vulkan_image_layout: usize,
    get_vulkan_resource_info: usize,
    lock_command_queue: usize,
    unlock_command_queue: usize,
    get_vulkan_resource_info1: usize,
    create_interop_command_queue: usize,
    create_interop_command_allocator: usize,
    begin_vk_command_buffer_interop: usize,
    end_vk_command_buffer_interop: usize,
    lock_vulkan_queue: usize,
    unlock_vulkan_queue: usize,
    get_vulkan_heap_info: unsafe extern "system" fn(*mut c_void, *mut c_void, *mut u64, *mut u64, *mut u32) -> HRESULT,
}

// Vulkan, as far as it is called here.
const VK_STRUCTURE_TYPE_MEMORY_MAP_INFO: u32 = 1_000_271_000;
const VK_STRUCTURE_TYPE_MEMORY_UNMAP_INFO: u32 = 1_000_271_001;
const VK_STRUCTURE_TYPE_MEMORY_MAP_PLACED_INFO_EXT: u32 = 1_000_272_002;
const VK_MEMORY_MAP_PLACED_BIT_EXT: u32 = 1;
const VK_MEMORY_UNMAP_RESERVE_BIT_EXT: u32 = 1;

#[repr(C)]
struct VkMemoryMapInfo {
    s_type: u32,
    p_next: *const c_void,
    flags: u32,
    memory: u64,
    offset: u64,
    size: u64,
}

#[repr(C)]
struct VkMemoryUnmapInfo {
    s_type: u32,
    p_next: *const c_void,
    flags: u32,
    memory: u64,
}

#[repr(C)]
struct VkMemoryMapPlacedInfoExt {
    s_type: u32,
    p_next: *const c_void,
    placed_address: *mut c_void,
}

type PfnMap2 = unsafe extern "system" fn(u64, *const VkMemoryMapInfo, *mut *mut c_void) -> i32;
type PfnUnmap2 = unsafe extern "system" fn(u64, *const VkMemoryUnmapInfo) -> i32;

struct Vk {
    map2: PfnMap2,
    unmap2: PfnUnmap2,
}

/// `vkMapMemory2` and `vkUnmapMemory2` from `vulkan-1.dll`; `None` (said
/// once) if either is missing.
fn vk() -> Option<&'static Vk> {
    static VK: OnceLock<Option<Vk>> = OnceLock::new();
    VK.get_or_init(|| {
        use windows_sys::Win32::System::LibraryLoader::{GetModuleHandleA, GetProcAddress, LoadLibraryA};
        // SAFETY: plain lookups; the module stays loaded for good (vkd3d
        // holds it too).
        let found = unsafe {
            let mut module = GetModuleHandleA(c"vulkan-1.dll".as_ptr().cast());
            if module.is_null() {
                module = LoadLibraryA(c"vulkan-1.dll".as_ptr().cast());
            }
            if module.is_null() {
                None
            } else {
                let map2 = GetProcAddress(module, c"vkMapMemory2".as_ptr().cast());
                let unmap2 = GetProcAddress(module, c"vkUnmapMemory2".as_ptr().cast());
                match (map2, unmap2) {
                    // SAFETY: the exports' C signatures.
                    (Some(map2), Some(unmap2)) => Some(Vk {
                        map2: std::mem::transmute::<unsafe extern "system" fn() -> isize, PfnMap2>(map2),
                        unmap2: std::mem::transmute::<unsafe extern "system" fn() -> isize, PfnUnmap2>(unmap2),
                    }),
                    _ => None,
                }
            }
        };
        if found.is_none() {
            tracing::warn!("renderer port 1 placed: vulkan-1.dll has no vkMapMemory2/vkUnmapMemory2: port 1 as before");
        }
        found
    })
    .as_ref()
}

/// Before `xmem` takes its locks: the host device and the Vulkan entry
/// points, made once (making them under the mapping locks would hold the
/// title's faults for that long).
pub fn warm() {
    let _ = crate::host::host();
    let _ = vk();
}

/// A heap ready to be mapped at the title's address: vkd3d's own mapping of
/// it let go (its addresses kept reserved).
pub struct Prepared {
    heap: ID3D12Heap,
    device: u64,
    memory: u64,
    bytes: u64,
}

// SAFETY: D3D12 heaps are free-threaded; the rest are plain handles.
unsafe impl Send for Prepared {}

/// Calls `vkUnmapMemory2` with `RESERVE`: the CPU mapping goes, its
/// addresses stay reserved (inaccessible) so that nothing else lands there.
fn unmap_reserving(vk: &Vk, device: u64, memory: u64) -> i32 {
    let info = VkMemoryUnmapInfo { s_type: VK_STRUCTURE_TYPE_MEMORY_UNMAP_INFO, p_next: std::ptr::null(), flags: VK_MEMORY_UNMAP_RESERVE_BIT_EXT, memory };
    // SAFETY: vkd3d's live device and a memory of it that is mapped.
    unsafe { (vk.unmap2)(device, &info) }
}

/// A heap of `bytes` (64 KiB pages, at most 4 GiB) whose memory is one
/// Vulkan allocation of its own, unmapped from vkd3d's address. `Err` with
/// why; nothing of the title's is touched yet.
pub fn prepare(bytes: usize) -> Result<Prepared, String> {
    let bytes = bytes as u64;
    if bytes == 0 || !bytes.is_multiple_of(K64) || bytes > MOST {
        return Err(format!("{bytes:#x} bytes: not 64 KiB pages, or over 4 GiB"));
    }
    let vk = vk().ok_or("no vkMapMemory2/vkUnmapMemory2 in vulkan-1.dll")?;
    let host = crate::host::host().ok_or("no host device")?;
    let desc = D3D12_HEAP_DESC {
        SizeInBytes: bytes,
        Properties: D3D12_HEAP_PROPERTIES {
            Type: D3D12_HEAP_TYPE_CUSTOM,
            CPUPageProperty: D3D12_CPU_PAGE_PROPERTY_WRITE_BACK,
            MemoryPoolPreference: D3D12_MEMORY_POOL_L0,
            CreationNodeMask: 0,
            VisibleNodeMask: 0,
        },
        Alignment: 0,
        Flags: D3D12_HEAP_FLAG_ALLOW_ONLY_BUFFERS,
    };
    let mut heap: Option<ID3D12Heap> = None;
    // SAFETY: plain creation with a valid description.
    unsafe { host.device.CreateHeap(&desc, &mut heap) }.map_err(|e| format!("no heap of {bytes:#x} bytes: {e}"))?;
    let heap = heap.ok_or("no heap")?;
    // SAFETY: a live heap.
    let made = unsafe { heap.GetDesc() }.SizeInBytes;
    if made != bytes {
        return Err(format!("the heap has {made:#x} bytes, not {bytes:#x}"));
    }
    let mut interop: *mut c_void = std::ptr::null_mut();
    // SAFETY: a COM query with a valid out pointer.
    let hr = unsafe { host.device.query(&IID_INTEROP3, &mut interop) };
    if hr.is_err() || interop.is_null() {
        return Err(format!("no ID3D12DXVKInteropDevice3 (not vkd3d-proton?): {hr:?}"));
    }
    // SAFETY: a live interface of the layout above; released below.
    let (device, memory, offset, hr) = unsafe {
        let vt = &**(interop as *mut *const InteropVtbl);
        let (mut instance, mut physical, mut device) = (0u64, 0u64, 0u64);
        let handles = (vt.get_vulkan_handles)(interop, &mut instance, &mut physical, &mut device);
        let (mut memory, mut offset, mut kind) = (0u64, u64::MAX, 0u32);
        let hr = if handles.is_ok() { (vt.get_vulkan_heap_info)(interop, heap.as_raw(), &mut memory, &mut offset, &mut kind) } else { handles };
        (vt.release)(interop);
        (device, memory, offset, hr)
    };
    if hr.is_err() || device == 0 || memory == 0 {
        return Err(format!("GetVulkanHandles/GetVulkanHeapInfo refused: {hr:?}"));
    }
    if offset != 0 {
        return Err(format!("the heap is at offset {offset:#x} of its Vulkan allocation, not a whole one"));
    }
    let r = unmap_reserving(vk, device, memory);
    if r != 0 {
        return Err(format!("vkUnmapMemory2(RESERVE) of vkd3d's mapping: VkResult {r}"));
    }
    Ok(Prepared { heap, device, memory, bytes })
}

/// Maps `prepared` at `at`, whose `bytes` are committed read-write memory of
/// the process (the driver maps over them). `Err` with why; nothing is
/// mapped there then.
pub fn map(prepared: &Prepared, at: usize) -> Result<(), String> {
    let vk = vk().ok_or("no vulkan entry points")?;
    let placed = VkMemoryMapPlacedInfoExt { s_type: VK_STRUCTURE_TYPE_MEMORY_MAP_PLACED_INFO_EXT, p_next: std::ptr::null(), placed_address: at as *mut c_void };
    let info = VkMemoryMapInfo {
        s_type: VK_STRUCTURE_TYPE_MEMORY_MAP_INFO,
        p_next: (&raw const placed).cast(),
        flags: VK_MEMORY_MAP_PLACED_BIT_EXT,
        memory: prepared.memory,
        offset: 0,
        size: u64::MAX,
    };
    let mut got: *mut c_void = std::ptr::null_mut();
    // SAFETY: vkd3d's live device and an unmapped memory of it; `placed`
    // outlives the call.
    let r = unsafe { (vk.map2)(prepared.device, &info, &mut got) };
    if r == 0 && got as usize == at {
        return Ok(());
    }
    if r == 0 && !got.is_null() {
        // Mapped, but not where asked (the extension is not on): let go.
        let plain = VkMemoryUnmapInfo { s_type: VK_STRUCTURE_TYPE_MEMORY_UNMAP_INFO, p_next: std::ptr::null(), flags: 0, memory: prepared.memory };
        // SAFETY: the mapping just made.
        unsafe { (vk.unmap2)(prepared.device, &plain) };
    }
    static SAID: std::sync::Once = std::sync::Once::new();
    SAID.call_once(|| {
        tracing::warn!(
            result = r,
            got = format_args!("{got:p}"),
            at = format_args!("{at:#x}"),
            "renderer port 1 placed: vkMapMemory2(PLACED) refused or mapped elsewhere: is VK_LAYER_VICTORY_placed on (ENABLE_VICTORY_PLACED=1)? Port 1 as before"
        );
    });
    Err(format!("vkMapMemory2(PLACED at {at:#x}): VkResult {r}, mapped at {got:p}"))
}

/// The mapping [`map`] made is let go again (its addresses kept reserved,
/// inaccessible) before `xmem` gives them back to the process: placing
/// failed after it.
pub fn unmap(prepared: &Prepared) {
    if let Some(vk) = vk() {
        let r = unmap_reserving(vk, prepared.device, prepared.memory);
        if r != 0 {
            tracing::warn!(result = r, "renderer port 1 placed: the placed mapping not let go");
        }
    }
}

/// The heap mapped at `at` (after [`map`]) becomes port 1's region there.
/// Call after the GPU side was told the memory is new
/// (`crate::title_memory_remapped`), which forgets port 1's regions over it.
pub fn register(prepared: Prepared, at: usize) {
    let Prepared { heap, device, memory, bytes } = prepared;
    crate::port::add_placed(at as u64, bytes, heap, device, memory);
    STATS[0].fetch_add(1, Ordering::Relaxed);
    STATS[1].fetch_add(bytes, Ordering::Relaxed);
    tracing::info!(
        at = format_args!("{at:#x}"),
        bytes,
        "renderer port 1 placed: the title's 32-bit graphics reservation is the card's allocation, mapped at the title's address (no userptr, no section view)"
    );
}

/// Port 1's placed regions over `[at, at + len)` are let go: what is placed
/// in them is retired, and the CPU mapping at the title's address is
/// unmapped keeping its addresses reserved (inaccessible) until `xmem` gives
/// them back to the process's own bookkeeping. Bytes let go.
pub fn release(at: usize, len: usize) -> u64 {
    let gone = crate::port::take_placed(at as u64, len as u64);
    let mut bytes = 0;
    for (start, end, heap, device, memory) in gone {
        crate::shadow::in_place_let_go(start, end - start);
        let r = vk().map_or(-1, |vk| unmap_reserving(vk, device, memory));
        bytes += end - start;
        STATS[3].fetch_add(1, Ordering::Relaxed);
        STATS[4].fetch_add(end - start, Ordering::Relaxed);
        tracing::warn!(
            start = format_args!("{start:#x}"),
            bytes = end - start,
            unmap = r,
            "renderer port 1 placed: a placed region let go (its GPU mapping unmapped, addresses kept reserved)"
        );
        // The heap goes when the last list and slot that hold it do.
        drop(heap);
    }
    bytes
}

/// Port 1's old path is kept for a reservation, and why.
pub fn fallback(why: &str) {
    let n = STATS[2].fetch_add(1, Ordering::Relaxed) + 1;
    if n <= 8 || n.is_power_of_two() {
        tracing::warn!(why, "renderer port 1 placed: not placed, port 1 as before (section views, heap opened from an address)");
    }
}

/// Port 1 was told to forget a placed region (kept).
pub(crate) fn kept() {
    STATS[5].fetch_add(1, Ordering::Relaxed);
}

/// The frame-rate line's.
pub(crate) fn log() {
    if !on() {
        return;
    }
    let s: Vec<u64> = STATS.iter().map(|s| s.load(Ordering::Relaxed)).collect();
    tracing::info!(
        "renderer port 1 placed (VICTORY_PORT_PLACED=1): {} heaps placed at the title's address ({} MB), {} fallbacks to port 1 as before; \
         {} let go again ({} MB); {} forgets of a placed region kept",
        s[0],
        s[1] >> 20,
        s[2],
        s[3],
        s[4] >> 20,
        s[5],
    );
}
