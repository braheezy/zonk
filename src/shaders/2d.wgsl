struct VertexInput {
    @location(0) position: vec2<f32>,
    @location(1) color: vec4<f32>,
    @location(2) uv: vec2<f32>,
};

struct VertexOutput {
    @builtin(position) position: vec4<f32>,
    @location(0) color: vec4<f32>,
    @location(1) uv: vec2<f32>,
};

struct DrawOptions {
    color: vec4<f32>,
};

@group(0) @binding(0) var<uniform> options: DrawOptions;
@group(0) @binding(1) var screen_texture: texture_2d<f32>;
@group(0) @binding(2) var screen_sampler: sampler;

@vertex
fn vs_main(input: VertexInput) -> VertexOutput {
    var output: VertexOutput;
    output.position = vec4<f32>(input.position, 0.0, 1.0);
    output.color = input.color * options.color;
    output.uv = input.uv;
    return output;
}

@fragment
fn fs_main(input: VertexOutput) -> @location(0) vec4<f32> {
    let texture_color = textureSample(screen_texture, screen_sampler, input.uv);
    return input.color * texture_color;
}
