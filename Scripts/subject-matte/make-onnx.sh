#!/bin/zsh
# Makes the subject matte for Bezzle for Windows (see README.md): the same BiRefNet_HR that make.sh
# converts for the Mac, at the same revision and weights, exported to ONNX at 2,048 pixels for ONNX
# Runtime: build/onnx/BiRefNet-fp32.onnx, checked against PyTorch; from it BiRefNet.onnx, the one
# Windows ships, its weights kept to 8 bits as the Mac's are and its layers working in full precision
# (quantize_onnx.py); and BiRefNet-fp16.onnx, half precision, for comparison. It runs BiRefNet's own
# model code, so run it yourself.
#
#   Scripts/subject-matte/make-onnx.sh [a photo to check it on]
set -euo pipefail
here=${0:A:h}
build=$here/build
export UV_PYTHON_INSTALL_DIR=$build/pythons UV_CACHE_DIR=$build/uv-cache

# The environment and the model make.sh made; without them, make.sh first.
[[ -x $build/env/bin/python && -x $build/boot/bin/uv && -f $build/model/model.safetensors ]] \
  || { print -u2 "Run Scripts/subject-matte/make.sh first: it makes the environment and fetches the model"; exit 1; }
py=$build/env/bin/python

# What was measured and reviewed, as in make.sh.
typeset -A sums=(
  birefnet.py 2a45b4e0ece72d7c4212bca1a988e7d7e52bfe9f98ec59c58b8809c8a8b7a831
  BiRefNet_config.py e7b8c2a74f6cea6a59553d517f71d47f2c1d90e670a13416af17c25fe2f3dc52
  model.safetensors 9d678bafec0b0019fbb073b7fd02f05ede25dc4b15254f23b2fb0be333200c0d
)
for file sum in ${(kv)sums}; do
  [[ $(shasum -a 256 $build/model/$file | cut -d' ' -f1) == $sum ]] || { print -u2 "$file is not the one reviewed"; exit 1; }
done
mkdir -p $build/code/brn
cp $build/model/birefnet.py $build/model/BiRefNet_config.py $build/code/brn/
touch $build/code/brn/__init__.py

# ONNX and ONNX Runtime beside what make.sh installed, of the same time as its PyTorch.
VIRTUAL_ENV=$build/env $build/boot/bin/uv pip install -q onnx==1.18.0 onnxruntime==1.22.0

rm -rf $build/onnx
$py -I $here/export_onnx.py $build/code $build/model 2048 $build/onnx ${1:-}
# The one Windows ships: 8-bit weights, full-precision layers (README.md, "For Windows").
$py -I $here/quantize_onnx.py $build/onnx/BiRefNet-fp32.onnx $build/onnx/BiRefNet.onnx
$py -I -c "import onnx; onnx.checker.check_model('$build/onnx/BiRefNet.onnx')"
du -sh $build/onnx/*.onnx
shasum -a 256 $build/onnx/BiRefNet.onnx
