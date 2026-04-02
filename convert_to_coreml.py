"""Convert Real-ESRGAN x2 PyTorch model to Core ML format."""

import torch
import torch.nn as nn
import torch.nn.functional as F
import coremltools as ct


# ── RRDBNet architecture (matches Real-ESRGAN x2plus weights) ──

class ResidualDenseBlock(nn.Module):
    def __init__(self, nf=64, gc=32):
        super().__init__()
        self.conv1 = nn.Conv2d(nf, gc, 3, 1, 1)
        self.conv2 = nn.Conv2d(nf + gc, gc, 3, 1, 1)
        self.conv3 = nn.Conv2d(nf + 2 * gc, gc, 3, 1, 1)
        self.conv4 = nn.Conv2d(nf + 3 * gc, gc, 3, 1, 1)
        self.conv5 = nn.Conv2d(nf + 4 * gc, nf, 3, 1, 1)
        self.lrelu = nn.LeakyReLU(negative_slope=0.2, inplace=True)

    def forward(self, x):
        x1 = self.lrelu(self.conv1(x))
        x2 = self.lrelu(self.conv2(torch.cat((x, x1), 1)))
        x3 = self.lrelu(self.conv3(torch.cat((x, x1, x2), 1)))
        x4 = self.lrelu(self.conv4(torch.cat((x, x1, x2, x3), 1)))
        x5 = self.conv5(torch.cat((x, x1, x2, x3, x4), 1))
        return x5 * 0.2 + x


class RRDB(nn.Module):
    def __init__(self, nf=64, gc=32):
        super().__init__()
        self.rdb1 = ResidualDenseBlock(nf, gc)
        self.rdb2 = ResidualDenseBlock(nf, gc)
        self.rdb3 = ResidualDenseBlock(nf, gc)

    def forward(self, x):
        out = self.rdb1(x)
        out = self.rdb2(out)
        out = self.rdb3(out)
        return out * 0.2 + x


class RRDBNet(nn.Module):
    def __init__(self, num_in_ch=3, num_out_ch=3, scale=2,
                 num_feat=64, num_block=23, num_grow_ch=32):
        super().__init__()
        self.scale = scale
        # For scale=2, the model uses pixel unshuffle on input (3ch -> 12ch, H -> H/2)
        # then two 2x upsamples in the body to reach 2x output.
        if scale == 2:
            num_in_ch = num_in_ch * 4
        self.conv_first = nn.Conv2d(num_in_ch, num_feat, 3, 1, 1)
        self.body = nn.Sequential(*[RRDB(num_feat, num_grow_ch) for _ in range(num_block)])
        self.conv_body = nn.Conv2d(num_feat, num_feat, 3, 1, 1)
        # Two upsampling stages (pixel_unshuffle halved, so we need 2x2x = 4x to get net 2x)
        self.conv_up1 = nn.Conv2d(num_feat, num_feat, 3, 1, 1)
        self.conv_up2 = nn.Conv2d(num_feat, num_feat, 3, 1, 1)
        self.conv_hr = nn.Conv2d(num_feat, num_feat, 3, 1, 1)
        self.conv_last = nn.Conv2d(num_feat, num_out_ch, 3, 1, 1)
        self.lrelu = nn.LeakyReLU(negative_slope=0.2, inplace=True)

    def forward(self, x):
        if self.scale == 2:
            x = F.pixel_unshuffle(x, 2)
        feat = self.conv_first(x)
        body_feat = self.conv_body(self.body(feat))
        feat = feat + body_feat
        feat = self.lrelu(self.conv_up1(F.interpolate(feat, scale_factor=2, mode='nearest')))
        feat = self.lrelu(self.conv_up2(F.interpolate(feat, scale_factor=2, mode='nearest')))
        out = self.conv_last(self.lrelu(self.conv_hr(feat)))
        return out


def main():
    print("Loading Real-ESRGAN x2 weights...")
    model = RRDBNet(num_in_ch=3, num_out_ch=3, scale=2,
                    num_feat=64, num_block=23, num_grow_ch=32)

    state_dict = torch.load('RealESRGAN_x2plus.pth', map_location='cpu', weights_only=True)
    if 'params_ema' in state_dict:
        state_dict = state_dict['params_ema']
    elif 'params' in state_dict:
        state_dict = state_dict['params']

    model.load_state_dict(state_dict, strict=True)
    model.eval()
    print("Weights loaded successfully.")

    # Wrap model to clamp output to [0, 255] range for image output
    class ClampedModel(nn.Module):
        def __init__(self, model):
            super().__init__()
            self.model = model

        def forward(self, x):
            out = self.model(x)
            return torch.clamp(out, 0.0, 1.0) * 255.0

    wrapped = ClampedModel(model)
    wrapped.eval()

    # Trace with a sample input
    tile_size = 256
    print(f"Tracing model with {tile_size}x{tile_size} input...")
    example_input = torch.randn(1, 3, tile_size, tile_size)
    with torch.no_grad():
        traced_model = torch.jit.trace(wrapped, example_input)

    # Verify output shape
    with torch.no_grad():
        out = traced_model(example_input)
    print(f"Input: {example_input.shape} -> Output: {out.shape}")

    # Convert to Core ML with flexible input size
    print("Converting to Core ML (flexible input 64-2048, even dims only)...")
    mlmodel = ct.convert(
        traced_model,
        inputs=[ct.ImageType(
            name="image",
            shape=ct.Shape(shape=(1, 3,
                ct.RangeDim(lower_bound=64, upper_bound=2048, default=256),
                ct.RangeDim(lower_bound=64, upper_bound=2048, default=256))),
            scale=1.0 / 255.0,
            bias=[0, 0, 0],
            color_layout="RGB",
        )],
        outputs=[ct.ImageType(name="output", color_layout="RGB")],
        minimum_deployment_target=ct.target.macOS15,
        compute_precision=ct.precision.FLOAT16,
    )

    output_path = "fishEye/SuperResolution.mlpackage"
    mlmodel.save(output_path)
    print(f"Saved Core ML model to {output_path}")
    print("Drag this file into the Xcode project. Xcode compiles it to .mlmodelc at build time.")


if __name__ == "__main__":
    main()
