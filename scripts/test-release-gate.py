#!/usr/bin/env python3
"""Check that publication fails closed without contacting GitHub."""
import importlib.util
from pathlib import Path
import subprocess
import sys
from unittest.mock import patch

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('publish', Path(__file__).with_name('publish-release.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
with patch.object(sys, 'argv', ['publish', '--check-only']), patch.object(module.subprocess, 'run') as run:
    run.return_value = subprocess.CompletedProcess([], 7, stdout='FAIL: regression\n')
    assert module.main() == 7
    assert run.call_count == 1, 'Upload must not run after a failed preflight'
    assert '--live' in run.call_args.args[0]
print('PASS: failed preflight propagates failure and never invokes upload')
with patch.object(sys, 'argv', ['publish', '--check-only']), patch.object(module.subprocess, 'run') as run:
    run.return_value = subprocess.CompletedProcess([], 0, stdout='PASS but missing report\n')
    try:
        module.main()
        raise AssertionError('Missing report must fail closed')
    except RuntimeError as error:
        assert 'report' in str(error)
    assert run.call_count == 1
print('PASS: missing report blocks publication')
