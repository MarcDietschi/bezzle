# sizes.py <out.mlpackage> <side>=<full.mlpackage> ...
# Keeps each converted model's weights to 8 bits and puts them in one package as functions named
# side<side>, the first given being the one a caller gets that names none. The models differ only
# in the size of picture they take, so Core ML keeps the weights they share once: two sizes come
# to hardly more than one.
import os, shutil, sys
import coremltools as ct
import coremltools.optimize.coreml as o

out, given = sys.argv[1], [pair.split('=', 1) for pair in sys.argv[2:]]
config = o.OptimizationConfig(global_config=o.OpLinearQuantizerConfig(mode='linear_symmetric', granularity='per_channel'))
sizes = ct.utils.MultiFunctionDescriptor()
for side, full in given:
    small = os.path.join(os.path.dirname(full), f'int8-{side}.mlpackage')
    shutil.rmtree(small, ignore_errors=True)
    o.linear_quantize_weights(ct.models.MLModel(full, skip_model_load=True), config).save(small)
    sizes.add_function(small, src_function_name='main', target_function_name=f'side{side}')
sizes.default_function_name = f'side{given[0][0]}'
shutil.rmtree(out, ignore_errors=True)
ct.utils.save_multifunction(sizes, out)
