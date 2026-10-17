"""Builds the Core ML model the iOS background probe times on the Neural Engine.

Eight 1x1 convolutions of 1024 channels over 512 positions, FP16: about
8.6 GFLOP and 16 MiB of weights per prediction. The work is the kind the
Neural Engine runs fast and the CPU does not, so a prediction's time says which
of the two ran it. The weights are seeded noise; the output is not checked.

    python make_ane_probe_model.py <out-dir>
    xcrun coremlcompiler compile <out-dir>/ane-probe.mlpackage <out-dir>

then push `ane-probe.mlmodelc` to the app's Documents.
"""
import sys

import coremltools as ct
import numpy as np
from coremltools.converters.mil import Builder as mb
from coremltools.converters.mil.mil import types

CHANNELS, POSITIONS, LAYERS = 1024, 512, 8
rng = np.random.default_rng(20261009)
weights = [(rng.standard_normal((CHANNELS, CHANNELS, 1, 1)) * 0.03).astype(np.float16)
           for _ in range(LAYERS)]


@mb.program(input_specs=[mb.TensorSpec(shape=(1, CHANNELS, 1, POSITIONS), dtype=types.fp16)],
            opset_version=ct.target.iOS17)
def program(x):
    for w in weights:
        x = mb.relu(x=mb.conv(x=x, weight=w))
    return x


model = ct.convert(program, convert_to="mlprogram",
                   minimum_deployment_target=ct.target.iOS17,
                   skip_model_load=True)  # loading it on the Mac can hang; the phone loads it
model.save(f"{sys.argv[1]}/ane-probe.mlpackage")
