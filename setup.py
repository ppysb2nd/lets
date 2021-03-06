"""Cython build file"""
from distutils.core import setup
from distutils.extension import Extension
from Cython.Build import cythonize
from os import walk, getcwd, path

cythonExt = []
for root, dirs, files in walk(getcwd()):
	for file in files:
		if file.endswith(".pyx") and ".pyenv" not in root:	# im sorry
			filePath = path.relpath(path.join(root, file))
			cythonExt.append(Extension(filePath.replace("/", ".")[:-4], [filePath]))

setup(
    name = "lets pyx modules",
    ext_modules = cythonize(cythonExt, nthreads = 4),
)
