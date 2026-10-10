"""Reproduce a package export rejecting our partially defined OIIO target set."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

@unittest.skipUnless(shutil.which('cmake'), 'CMake required')
class OIIOImport(unittest.TestCase):
    def configure(self, helper):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root/'modules').mkdir()
            (root/'lib').mkdir()
            (root/'modules/FindOpenGL.cmake').write_text('add_library(OpenGL::GL INTERFACE IMPORTED)\n')
            (root/'modules/ImathConfig.cmake').write_text('add_library(Imath::Imath INTERFACE IMPORTED)\n')
            (root/'modules/OpenImageIOConfig.cmake').write_text('''
if(TARGET OpenImageIO::OpenImageIO AND NOT TARGET OpenImageIO::OpenImageIO_Util)
  message(FATAL_ERROR "Some (but not all) targets in this export set were already defined")
endif()
if(NOT TARGET OpenImageIO::OpenImageIO)
  add_library(OpenImageIO::OpenImageIO INTERFACE IMPORTED)
  add_library(OpenImageIO::OpenImageIO_Util INTERFACE IMPORTED)
endif()
''')
            for suffix in ['.so', '.dylib']:
                (root/('lib/libOpenImageIO'+suffix)).touch()
                (root/('lib/libOpenImageIO_Util'+suffix)).touch()
            (root/'helper.cmake').write_text(helper)
            (root/'CMakeLists.txt').write_text('''cmake_minimum_required(VERSION 3.21)
project(import_check NONE)
list(PREPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/modules")
set(Imath_DIR "${CMAKE_CURRENT_SOURCE_DIR}/modules")
set(OpenImageIO_DIR "${CMAKE_CURRENT_SOURCE_DIR}/modules")
list(PREPEND CMAKE_LIBRARY_PATH "${CMAKE_CURRENT_SOURCE_DIR}/lib")
include(helper.cmake)
find_package(OpenImageIO CONFIG REQUIRED)
if(NOT TARGET OpenImageIO::OpenImageIO_Util)
  message(FATAL_ERROR "Util target missing")
endif()
''')
            return subprocess.run(['cmake','-S',str(root),'-B',str(root/'build')], capture_output=True,text=True)

    def test_full_package_prevents_later_export_collision(self):
        before = subprocess.check_output(['git','show','db7a128:cmake/import_openusd_dependencies.cmake'],cwd=ROOT,text=True)
        old = self.configure(before)
        self.assertNotEqual(old.returncode, 0)
        self.assertIn('Some (but not all) targets', old.stderr)
        new = self.configure((ROOT/'cmake/import_openusd_dependencies.cmake').read_text())
        self.assertEqual(new.returncode, 0, new.stdout+new.stderr)
