use std::alloc::{GlobalAlloc, Layout, System};
use std::ptr;

/// Blocks of 1 MiB and more come from the kernel and go back to it when freed. macOS malloc keeps freed large blocks
/// dirty for reuse, about 100 MB of them, and they count in the app's footprint while it idles: a whole parse of a
/// 10 MB document frees more than that.
struct Allocator;

#[global_allocator]
static ALLOCATOR: Allocator = Allocator;

const DIRECT: usize = 1 << 20;
/// The smallest page size, Intel's; `mmap` aligns to it.
const PAGE: usize = 4096;

fn direct(layout: Layout) -> bool {
    layout.size() >= DIRECT && layout.align() <= PAGE
}

unsafe impl GlobalAlloc for Allocator {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        if !direct(layout) {
            return unsafe { System.alloc(layout) };
        }
        let block = unsafe {
            libc::mmap(
                ptr::null_mut(),
                layout.size(),
                libc::PROT_READ | libc::PROT_WRITE,
                libc::MAP_PRIVATE | libc::MAP_ANON,
                -1,
                0,
            )
        };
        if block == libc::MAP_FAILED {
            ptr::null_mut()
        } else {
            block.cast()
        }
    }

    unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
        // The kernel's pages come zeroed.
        if direct(layout) {
            unsafe { self.alloc(layout) }
        } else {
            unsafe { System.alloc_zeroed(layout) }
        }
    }

    unsafe fn dealloc(&self, block: *mut u8, layout: Layout) {
        if direct(layout) {
            unsafe { libc::munmap(block.cast(), layout.size()) };
        } else {
            unsafe { System.dealloc(block, layout) }
        }
    }

    unsafe fn realloc(&self, block: *mut u8, layout: Layout, size: usize) -> *mut u8 {
        let new = unsafe { Layout::from_size_align_unchecked(size, layout.align()) };
        if !direct(layout) && !direct(new) {
            return unsafe { System.realloc(block, layout, size) };
        }
        let moved = unsafe { self.alloc(new) };
        if !moved.is_null() {
            unsafe {
                ptr::copy_nonoverlapping(block, moved, layout.size().min(size));
                self.dealloc(block, layout);
            }
        }
        moved
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn blocks_keep_their_bytes_across_the_threshold() {
        let mut bytes = Vec::new();
        for at in 0..3 * DIRECT {
            bytes.push(at as u8);
        }
        bytes.truncate(DIRECT / 2);
        bytes.shrink_to_fit();
        assert!(bytes.iter().enumerate().all(|(at, &byte)| byte == at as u8));
        assert!(vec![0u8; 2 * DIRECT].iter().all(|&byte| byte == 0));
    }
}
