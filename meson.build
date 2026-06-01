project('singularity-monitor', ['vala', 'c'],
  version: '0.1.0',
  meson_version: '>= 0.59.0'
)

gnome    = import('gnome')
cc       = meson.get_compiler('c')

gtk_dep   = dependency('gtk4')
gee_dep   = dependency('gee-0.8')
cairo_dep = dependency('cairo')
math_dep  = cc.find_library('m')

libsingularity_dep = dependency('singularity-1.0',
  fallback: ['libsingularity', 'libsingularity_dep']
)

if not meson.is_subproject() and libsingularity_dep.type_name() == 'internal'
  libsingularity_vapi_dir = join_paths(meson.project_build_root(), 'subprojects', 'libsingularity')
  add_project_arguments(['--vapidir=' + libsingularity_vapi_dir], language: 'vala')
endif

subdir('ui')

resources = gnome.compile_resources(
  'singularity-monitor-resources',
  'resources/dev.sinty.monitor.gresource.xml',
  source_dir: [meson.current_source_dir(), meson.current_build_dir()],
  dependencies: main_ui
)

sources = files(
  'src/main.vala',
  'src/models.vala',
  'src/window.vala',
  'src/app.vala',
)

executable('singularity-monitor',
  sources + [resources],
  dependencies: [gtk_dep, gee_dep, math_dep, libsingularity_dep],
  vala_args: ['--pkg=posix'],
  install: true
)

shared_module('singularity-monitor-widget',
  files('widget/system_stats_widget.vala'),
  dependencies: [gtk_dep, cairo_dep, libsingularity_dep],
  install: true,
  install_dir: get_option('libdir') / 'singularity' / 'widgets'
)
install_data('widget/dev.sinty.monitor.system-stats.widget',
  install_dir: get_option('datadir') / 'singularity' / 'widgets'
)

install_data('data/dev.sinty.monitor.desktop',
  install_dir: get_option('datadir') / 'applications'
)
install_data('data/dev.sinty.monitor.gschema.xml',
  install_dir: get_option('datadir') / 'glib-2.0' / 'schemas'
)
install_data('data/dev.sinty.monitor.json',
  install_dir: get_option('datadir') / 'singularity' / 'app-settings'
)
install_data('data/icons/dev.sinty.monitor.svg',
  install_dir: get_option('datadir') / 'icons' / 'hicolor' / 'scalable' / 'apps'
)
