"""Original Magenta weights, with style/content bottleneck interpolation."""
import json
import os
import time
from pathlib import Path
import numpy as np
from PIL import Image
from .config import ROOT, sha_file, write_json
from .data import SPLITS, audit, content, paired, selected_indices, source_signature


def model_hashes(cfg):
    reference = json.loads((ROOT / 'provenance/magenta_weights.json').read_text())
    hashes = {}
    for row in reference['files']:
        path = Path(cfg['paths']['magenta']) / row['file']
        value = sha_file(path)
        if value != row['sha256']:
            raise ValueError(f'Magenta weight hash mismatch: {path}')
        hashes[row['file']] = value
    return hashes


def generate(cfg):
    output = Path(cfg['paths']['targets'])
    hashes = model_hashes(cfg)
    if (output / 'manifest.json').exists():
        old = json.loads((output / 'manifest.json').read_text())
        if old['model_files_sha256'] != hashes:
            raise ValueError('Cached targets were generated with different teacher weights')
        for split in SPLITS:
            paired(cfg, split)
        print('Reusing verified teacher target cache', output, flush=True)
        return
    # Imported only by the dedicated TensorFlow interpreter, never by training.
    os.environ['TF_CPP_MIN_LOG_LEVEL'] = '2'
    os.environ['CUDA_VISIBLE_DEVICES'] = ''
    import tensorflow as tf
    from tensorflow.python.framework.convert_to_constants import convert_variables_to_constants_v2
    tf.config.threading.set_intra_op_parallelism_threads(cfg['teacher']['cpu_threads'])
    tf.config.threading.set_inter_op_parallelism_threads(1)
    dataset_audit = audit(cfg)
    output.mkdir(parents=True, exist_ok=False)
    started = time.time()
    model = tf.saved_model.load(cfg['paths']['magenta'])
    frozen = convert_variables_to_constants_v2(model.__call__)
    graph = frozen.graph.as_graph_def()
    wrapped = tf.compat.v1.wrap_function(lambda: tf.compat.v1.import_graph_def(graph, name=''), [])
    get = wrapped.graph.get_tensor_by_name
    code = get('bottleneck/Mean:0')
    encoder = wrapped.prune(get('placeholder_1:0'), code)
    decoder = wrapped.prune([get('placeholder:0'), code], get('transformer/expand/conv3/conv/Sigmoid:0'))
    style = np.asarray(Image.open(cfg['paths']['style']).convert('RGB').resize((256, 256), Image.Resampling.BILINEAR), np.float32)[None] / 255
    style_code = encoder(tf.constant(style))
    alpha = cfg['teacher']['strength']

    @tf.function(input_signature=[tf.TensorSpec([None, 144, 256, 3], tf.float32)])
    def forward(x):
        content_code = encoder(tf.image.resize(x, (256, 256)))
        return decoder(x, style_code * alpha + content_code * (1 - alpha))

    probe = np.asarray(content(cfg, 'train')[:1]).transpose(0, 2, 3, 1).astype('float32') / 255
    original = model(tf.constant(probe), tf.constant(style))[0].numpy()
    frozen_full = decoder(tf.constant(probe), style_code).numpy()
    difference = float(np.abs(original - frozen_full).max())
    if difference > 1e-6:
        raise ValueError(f'Frozen teacher is not equivalent to the original: {difference}')
    indices, target_sha = {}, {}
    for split in SPLITS:
        x = content(cfg, split)
        ids = selected_indices(cfg, split, len(x))
        indices[split] = ids.tolist()
        path = output / f'{split}_target.npy'
        dest = np.lib.format.open_memmap(path, mode='w+', dtype='uint8', shape=(len(ids), 3, 144, 256))
        batch = cfg['teacher']['batch']
        for start in range(0, len(ids), batch):
            xx = np.asarray(x[ids[start:start + batch]]).transpose(0, 2, 3, 1).astype('float32') / 255
            y = forward(tf.constant(xx)).numpy()
            dest[start:start + len(y)] = (y.clip(0, 1) * 255).round().astype('uint8').transpose(0, 3, 1, 2)
            if start % (batch * 32) == 0:
                print(json.dumps({'split': split, 'images': min(start + batch, len(ids)), 'elapsed_s': time.time() - started}), flush=True)
        dest.flush()
        del dest
        target_sha[split] = sha_file(path)
    write_json(output / 'manifest.json', dict(completed=True, teacher=cfg['teacher'],
        model_files_sha256=hashes, style_sha256=sha_file(cfg['paths']['style']),
        content_sha256=dataset_audit['content_sha256'], target_sha256=target_sha, indices=indices,
        original_vs_frozen_full_style_max_difference=difference, reference_is_stylized_output=True,
        original_model_retrained=False, output_pixel_blending=False, tensorflow=tf.__version__, elapsed_s=time.time() - started))
    print('Teacher targets complete', output, flush=True)
