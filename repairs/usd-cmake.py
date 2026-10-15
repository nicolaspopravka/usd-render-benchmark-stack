#!/usr/bin/env python3
"""Repair the observed ASWF USD exports using native dependency packages."""
import os
from pathlib import Path
import re


def repair():
    prefix = Path(os.environ.get('ASWF_INSTALL_PREFIX', '/usr/local'))
    config = prefix / 'pxrConfig.cmake'
    exports = sorted((prefix / 'cmake').glob('pxrTargets*.cmake'))
    if not config.is_file() or not exports:
        raise ValueError('USD config or exports missing')
    packages = prefix / 'lib/cmake'
    for name, filename in (
            ('MaterialX', 'MaterialXConfig.cmake'), ('Imath', 'ImathConfig.cmake'),
            ('OpenColorIO', 'OpenColorIOConfig.cmake'),
            ('OpenSubdiv', 'OpenSubdivConfig.cmake'), ('Ptex', 'ptex-config.cmake')):
        if not (packages / name / filename).is_file():
            raise ValueError(f'native {name} config missing')

    text = {path: path.read_text() for path in [config, *exports]}
    usd = text[config]
    references = '\n'.join(text[path] for path in exports)
    python = re.search(r'(?:find_package|find_dependency)\(Python3 "(\d+)\.(\d+)\.', usd)
    boost = 'CONAN_LIB::boost_' in references or 'Boost::python' in references
    if boost:
        if not python:
            raise ValueError('USD Python version missing')
        component = 'python' + ''.join(python.groups())
        if not any(packages.glob('Boost-*/BoostConfig.cmake')):
            raise ValueError('native Boost config missing')
        if not (prefix / f'lib/libboost_{component}.so').is_file():
            raise ValueError(f'installed Boost {component} library missing')

    replacements = {
        'CONAN_LIB::materialx_materialx_MaterialXCore_MaterialXCore_RELEASE': 'MaterialXCore',
        'CONAN_LIB::materialx_materialx_MaterialXFormat_MaterialXFormat_RELEASE': 'MaterialXFormat',
        'CONAN_LIB::ptex_Ptex_Ptex_dynamic_Ptex_RELEASE': 'Ptex::Ptex_dynamic',
    }
    if boost:
        replacements[f'CONAN_LIB::boost_Boost_python_boost_{component}_RELEASE'] = 'Boost::python'
    for path in exports:
        for old, new in replacements.items():
            text[path] = text[path].replace(old, new)
        if 'CONAN_LIB::' in text[path]:
            raise ValueError(f'unrecognized Conan target in {path.name}')

    for name, directory in (
            ('MaterialX', 'MaterialX'), ('Imath', 'Imath'),
            ('OpenColorIO', 'OpenColorIO'), ('OpenVDB', 'OpenVDB'),
            ('PTex', 'Ptex')):
        pattern = rf'set\({name}_DIR \[\[(/opt/conan_home/[^\]\n]+)\]\]\)'
        match = re.search(pattern, usd)
        if match:
            usd = usd.replace('[[' + match.group(1) + ']]',
                              '"${PXR_CMAKE_DIR}/lib/cmake/' + directory + '"', 1)
            usd = re.sub(pattern,
                         f'set({name}_DIR "${{PXR_CMAKE_DIR}}/lib/cmake/{directory}")', usd)
    include = 'include("${PXR_CMAKE_DIR}/cmake/aswf-usd-dependencies.cmake")'
    anchor = 'include("${PXR_CMAKE_DIR}/cmake/pxrTargets.cmake")'
    if usd.count(anchor) != 1:
        raise ValueError('unexpected USD exports include')
    if include not in usd:
        usd = usd.replace(anchor, include + '\n' + anchor)
    text[config] = usd
    if any('/opt/conan_home/' in value or 'CONAN_LIB::' in value for value in text.values()):
        raise ValueError('unrecognized Conan reference in USD metadata')

    dependencies = ['include(CMakeFindDependencyMacro)', 'find_dependency(Threads)']
    dependencies += [f'find_dependency({name} CONFIG)' for name in
                     ('MaterialX', 'Imath', 'OpenColorIO', 'OpenSubdiv', 'Ptex', 'TBB', 'OpenVDB')]
    if 'OpenGL::GL' in references:
        dependencies.append('find_dependency(OpenGL)')
    if boost:
        dependencies.append(f'find_dependency(Boost CONFIG COMPONENTS {component})')
    text[prefix / 'cmake/aswf-usd-dependencies.cmake'] = '\n'.join(dependencies) + '\n'

    for name, library, header in (
            ('TBB', 'tbb', 'tbb/tbb.h'), ('OpenVDB', 'openvdb', 'openvdb/openvdb.h')):
        path = packages / name / f'{name}Config.cmake'
        if not path.exists():
            if not (prefix / f'lib/lib{library}.so').is_file() or not (prefix / 'include' / header).is_file():
                raise ValueError(f'installed {name} library or headers missing')
            text[path] = Path(__file__).with_name(f'{name}Config.cmake').read_text()

    # Keep the native exports; repair their observed dependency discovery/names.
    blosc = packages / 'Blosc/BloscConfig.cmake'
    if blosc.is_file():
        value = blosc.read_text().replace(
            'find_dependency(ZLIB REQUIRED CONFIG)', 'find_dependency(ZLIB REQUIRED)')
        alias = 'add_library(Blosc::blosc ALIAS Blosc::blosc_shared)'
        if alias not in value:
            value += '\nif(NOT TARGET Blosc::blosc)\n  ' + alias + '\nendif()\n'
        text[blosc] = value
    openvdb = packages / 'OpenVDB/OpenVDBConfig.cmake'
    if openvdb.is_file():
        value = openvdb.read_text()
        alias = 'add_library(OpenVDB::openvdb ALIAS OpenVDB::openvdb_shared)'
        if alias not in value:
            value += '\nif(NOT TARGET OpenVDB::openvdb)\n  ' + alias + '\nendif()\n'
        text[openvdb] = value

    # Complete validation before changing any installed metadata.
    for path, value in text.items():
        if not path.exists() or path.read_text() != value:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(value)


if __name__ == '__main__':
    try:
        repair()
    except (OSError, ValueError) as error:
        raise SystemExit(f'usd-cmake: {error}')
