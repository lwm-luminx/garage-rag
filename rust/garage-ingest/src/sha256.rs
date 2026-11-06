//! SHA-256 (FIPS 180-4), for `sha256_text` and the chunks' hashes: a few lines here rather than a
//! crate, since nothing else in the pipeline needs a digest library.

const K: [u32; 64] = [
    0x428a_2f98,
    0x7137_4491,
    0xb5c0_fbcf,
    0xe9b5_dba5,
    0x3956_c25b,
    0x59f1_11f1,
    0x923f_82a4,
    0xab1c_5ed5,
    0xd807_aa98,
    0x1283_5b01,
    0x2431_85be,
    0x550c_7dc3,
    0x72be_5d74,
    0x80de_b1fe,
    0x9bdc_06a7,
    0xc19b_f174,
    0xe49b_69c1,
    0xefbe_4786,
    0x0fc1_9dc6,
    0x240c_a1cc,
    0x2de9_2c6f,
    0x4a74_84aa,
    0x5cb0_a9dc,
    0x76f9_88da,
    0x983e_5152,
    0xa831_c66d,
    0xb003_27c8,
    0xbf59_7fc7,
    0xc6e0_0bf3,
    0xd5a7_9147,
    0x06ca_6351,
    0x1429_2967,
    0x27b7_0a85,
    0x2e1b_2138,
    0x4d2c_6dfc,
    0x5338_0d13,
    0x650a_7354,
    0x766a_0abb,
    0x81c2_c92e,
    0x9272_2c85,
    0xa2bf_e8a1,
    0xa81a_664b,
    0xc24b_8b70,
    0xc76c_51a3,
    0xd192_e819,
    0xd699_0624,
    0xf40e_3585,
    0x106a_a070,
    0x19a4_c116,
    0x1e37_6c08,
    0x2748_774c,
    0x34b0_bcb5,
    0x391c_0cb3,
    0x4ed8_aa4a,
    0x5b9c_ca4f,
    0x682e_6ff3,
    0x748f_82ee,
    0x78a5_636f,
    0x84c8_7814,
    0x8cc7_0208,
    0x90be_fffa,
    0xa450_6ceb,
    0xbef9_a3f7,
    0xc671_78f2,
];

const H0: [u32; 8] =
    [0x6a09_e667, 0xbb67_ae85, 0x3c6e_f372, 0xa54f_f53a, 0x510e_527f, 0x9b05_688c, 0x1f83_d9ab, 0x5be0_cd19];

// The working variables keep FIPS 180-4's names.
#[allow(clippy::many_single_char_names)]
fn compress(state: &mut [u32; 8], block: &[u8]) {
    let mut w = [0u32; 64];
    for (word, bytes) in w.iter_mut().zip(block.chunks_exact(4)) {
        *word = u32::from_be_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]);
    }
    for i in 16..64 {
        let s0 = w[i - 15].rotate_right(7) ^ w[i - 15].rotate_right(18) ^ (w[i - 15] >> 3);
        let s1 = w[i - 2].rotate_right(17) ^ w[i - 2].rotate_right(19) ^ (w[i - 2] >> 10);
        w[i] = w[i - 16].wrapping_add(s0).wrapping_add(w[i - 7]).wrapping_add(s1);
    }
    let [mut a, mut b, mut c, mut d, mut e, mut f, mut g, mut h] = *state;
    for (k, word) in K.iter().zip(w) {
        let s1 = e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25);
        let choose = (e & f) ^ (!e & g);
        let t1 = h.wrapping_add(s1).wrapping_add(choose).wrapping_add(*k).wrapping_add(word);
        let s0 = a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22);
        let majority = (a & b) ^ (a & c) ^ (b & c);
        let t2 = s0.wrapping_add(majority);
        h = g;
        g = f;
        f = e;
        e = d.wrapping_add(t1);
        d = c;
        c = b;
        b = a;
        a = t1.wrapping_add(t2);
    }
    for (slot, value) in state.iter_mut().zip([a, b, c, d, e, f, g, h]) {
        *slot = slot.wrapping_add(value);
    }
}

/// A digest fed in pieces, for a file read a block at a time (`base.file_sha256`).
#[derive(Clone, Debug)]
pub struct Hasher {
    state: [u32; 8],
    pending: [u8; 64],
    pending_len: usize,
    length: u64,
}

impl Default for Hasher {
    fn default() -> Self {
        Self { state: H0, pending: [0; 64], pending_len: 0, length: 0 }
    }
}

impl Hasher {
    /// Adds `bytes`.
    pub fn update(&mut self, mut bytes: &[u8]) {
        self.length = self.length.wrapping_add(bytes.len() as u64);
        if self.pending_len > 0 {
            let take = bytes.len().min(64 - self.pending_len);
            self.pending[self.pending_len..self.pending_len + take].copy_from_slice(&bytes[..take]);
            self.pending_len += take;
            bytes = &bytes[take..];
            if self.pending_len < 64 {
                return;
            }
            let block = self.pending;
            compress(&mut self.state, &block);
            self.pending_len = 0;
        }
        let mut blocks = bytes.chunks_exact(64);
        for block in &mut blocks {
            compress(&mut self.state, block);
        }
        let rest = blocks.remainder();
        self.pending[..rest.len()].copy_from_slice(rest);
        self.pending_len = rest.len();
    }

    /// The digest of everything added.
    #[must_use]
    pub fn finish(mut self) -> [u8; 32] {
        let rest = self.pending_len;
        let mut tail = [0u8; 128];
        tail[..rest].copy_from_slice(&self.pending[..rest]);
        tail[rest] = 0x80;
        let length = if rest < 56 { 64 } else { 128 };
        tail[length - 8..length].copy_from_slice(&self.length.wrapping_mul(8).to_be_bytes());
        for block in tail[..length].chunks_exact(64) {
            compress(&mut self.state, block);
        }
        let mut out = [0u8; 32];
        for (bytes, word) in out.chunks_exact_mut(4).zip(self.state) {
            bytes.copy_from_slice(&word.to_be_bytes());
        }
        out
    }
}

/// The SHA-256 digest of `bytes`.
#[must_use]
pub fn digest(bytes: &[u8]) -> [u8; 32] {
    let mut hasher = Hasher::default();
    hasher.update(bytes);
    hasher.finish()
}

/// The digest of a file's bytes, as lowercase hex, read a megabyte at a time (`base.file_sha256`).
///
/// # Errors
///
/// The file could not be opened or read.
pub fn file_hex_digest(path: &std::path::Path) -> std::io::Result<String> {
    use std::io::Read;
    let mut file = std::fs::File::open(path)?;
    let mut hasher = Hasher::default();
    let mut block = vec![0u8; 1 << 20];
    loop {
        let read = match file.read(&mut block) {
            Ok(0) => break,
            Ok(read) => read,
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(error) => return Err(error),
        };
        hasher.update(&block[..read]);
    }
    Ok(hex(&hasher.finish()))
}

/// The digest of `bytes`, as lowercase hex.
#[must_use]
pub fn hex_digest(bytes: &[u8]) -> String {
    hex(&digest(bytes))
}

fn hex(digest: &[u8; 32]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    digest.iter().flat_map(|byte| [HEX[usize::from(byte >> 4)], HEX[usize::from(byte & 15)]]).map(char::from).collect()
}

#[cfg(test)]
mod tests {
    use super::{Hasher, digest, hex_digest};

    #[test]
    fn known_answers() {
        assert_eq!(hex_digest(b""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
        assert_eq!(hex_digest(b"abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
        assert_eq!(
            hex_digest(b"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        );
        assert_eq!(
            hex_digest(&vec![b'a'; 1_000_000]),
            "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"
        );
        for length in 50..140 {
            assert_eq!(hex_digest(&vec![b'x'; length]).len(), 64);
        }
    }

    #[test]
    fn pieces_hash_as_the_whole() {
        let bytes: Vec<u8> = (0..1000_u32).map(|n| (n * 7 % 251) as u8).collect();
        for step in [1, 3, 63, 64, 65, 200, 1000] {
            let mut hasher = Hasher::default();
            for piece in bytes.chunks(step) {
                hasher.update(piece);
            }
            assert_eq!(hasher.finish(), digest(&bytes), "pieces of {step}");
        }
    }
}
