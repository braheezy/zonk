const AudioQueueRef = usize;
const AudioTimestamp = usize;
const audio_format_linear_pcm = 0x6C70636D; // 'lpcm'
const audio_format_flag_is_float = 1 << 0; // 0x1

// const AudioStreamBasicDescription

pub const Context = struct {
    pub fn init() !void {}
};
