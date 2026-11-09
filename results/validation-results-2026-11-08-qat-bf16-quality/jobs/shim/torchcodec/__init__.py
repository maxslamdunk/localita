# The cu129 vLLM image ships a torchcodec built for CUDA 13 (libnvrtc.so.13),
# whose load fails with OSError, which vLLM does not catch. Text-only runs
# need no audio, so present torchcodec as absent.
raise ImportError("torchcodec disabled: the image build targets CUDA 13")
