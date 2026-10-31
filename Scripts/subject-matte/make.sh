#!/bin/zsh
# Makes the subject matte that comes with the app (see README.md): BiRefNet_HR → Core ML →
# 8-bit weights → Bezzle/Canvas/BiRefNet.mlpackage, which Xcode compiles into the app.
# It runs BiRefNet's own model code, downloaded at the revision below, so run it yourself.
set -euo pipefail
here=${0:A:h}
build=$here/build
mkdir -p $build
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
export UV_PYTHON_INSTALL_DIR=$build/pythons UV_CACHE_DIR=$build/uv-cache

# What was measured and reviewed: this revision of the model, its code and weights as they were.
repo=ZhengPeng7/BiRefNet_HR
revision=a7a562f6fd16021180f2f4348f4de003a2d3d1e1
typeset -A sums=(
  birefnet.py 2a45b4e0ece72d7c4212bca1a988e7d7e52bfe9f98ec59c58b8809c8a8b7a831
  BiRefNet_config.py e7b8c2a74f6cea6a59553d517f71d47f2c1d90e670a13416af17c25fe2f3dc52
  model.safetensors 9d678bafec0b0019fbb073b7fd02f05ede25dc4b15254f23b2fb0be333200c0d
)

# Python 3.13, with what coremltools 9 was tested with; all of it kept in build/.
if [[ ! -x $build/env/bin/python ]]; then
  python3 -m venv $build/boot
  $build/boot/bin/pip install -q uv
  $build/boot/bin/uv python install 3.13
  $build/boot/bin/uv venv -q -p 3.13 $build/env
  VIRTUAL_ENV=$build/env $build/boot/bin/uv pip install -q coremltools==9.0 torch==2.7.0 torchvision==0.22.0 numpy==2.2.6 \
    safetensors==0.8.0 pillow==13.0.0 transformers==5.22.1 timm==1.0.30 kornia==0.9.0 einops==0.8.2 huggingface-hub==2.4.0
fi
py=$build/env/bin/python

$py -I -c "from huggingface_hub import snapshot_download as d; d('$repo', revision='$revision', local_dir='$build/model', allow_patterns=['*.py', '*.json', 'model.safetensors'])"
for file sum in ${(kv)sums}; do
  [[ $(shasum -a 256 $build/model/$file | cut -d' ' -f1) == $sum ]] || { print -u2 "$file is not the one reviewed"; exit 1; }
done
mkdir -p $build/code/brn
cp $build/model/birefnet.py $build/model/BiRefNet_config.py $build/code/brn/
touch $build/code/brn/__init__.py

rm -rf $build/full.mlpackage $build/int8.mlpackage
$py -I $here/convert.py $build/code $build/model 2048 $build/full.mlpackage ${1:-}
$py -I -c "
import coremltools as ct, coremltools.optimize.coreml as o
m = ct.models.MLModel('$build/full.mlpackage', skip_model_load=True)
o.linear_quantize_weights(m, o.OptimizationConfig(global_config=o.OpLinearQuantizerConfig(mode='linear_symmetric', granularity='per_channel'))).save('$build/int8.mlpackage')
"
target=$here/../../Bezzle/Canvas/BiRefNet.mlpackage
rm -rf $target
mv $build/int8.mlpackage $target
du -sh $target
