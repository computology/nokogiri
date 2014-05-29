# :stopdoc:
ENV['RC_ARCHS'] = '' if RUBY_PLATFORM =~ /darwin/

require 'mkmf'

ROOT = File.expand_path(File.join(File.dirname(__FILE__), '..', '..'))

#
# functions
#

def do_help
  print <<HELP
usage: ruby #{$0} [options]

    --disable-clean
        Do not clean out intermediate files after successful build.

    --disable-static
        Do not statically link bundled libraries.

    --with-iconv-dir=DIR
        Use the iconv library placed under DIR.

    --with-zlib-dir=DIR
        Use the zlib library placed under DIR.

    --use-system-libraries
        Use system libraries intead of building and using the bundled
        libraries.

    --with-xml2-dir=DIR / --with-xml2-config=CONFIG
    --with-xslt-dir=DIR / --with-xslt-config=CONFIG
    --with-exslt-dir=DIR / --with-exslt-config=CONFIG
        Use libxml2/libxslt/libexslt as specified.

    --enable-cross-build
        Do cross-build.
HELP
  exit! 0
end

def message!(important_message)
  message important_message
  if !$stdout.tty? && File.chardev?('/dev/tty')
    File.open('/dev/tty', 'w') { |tty|
      tty.print important_message
    }
  end
rescue Errno::ENXIO
end

def do_clean
  require 'pathname'
  require 'fileutils'

  root = Pathname(ROOT)
  pwd  = Pathname(Dir.pwd)

  # Skip if this is a development work tree
  unless (root + '.git').exist?
    message "Cleaning files only used during build.\n"

    # (root + 'tmp') cannot be removed at this stage because
    # nokogiri.so is yet to be copied to lib.

    # clean the ports build directory
    Pathname.glob(pwd.join('tmp', '*', 'ports')) { |dir|
      FileUtils.rm_rf(dir, verbose: true)
      FileUtils.rmdir(dir.parent, parents: true, verbose: true)
    }

    if enable_config('static')
      # ports installation can be safely removed if statically linked.
      FileUtils.rm_rf(root + 'ports', verbose: true)
    else
      FileUtils.rm_rf(root + 'ports' + 'archives', verbose: true)
    end
  end

  exit! 0
end

def preserving_globals
  values = [
    $arg_config,
    $CFLAGS, $CPPFLAGS,
    $LDFLAGS, $LIBPATH, $libs
  ].map(&:dup)
  yield
ensure
  $arg_config,
  $CFLAGS, $CPPFLAGS,
  $LDFLAGS, $LIBPATH, $libs =
    values
end

def asplode(lib)
  abort "-----\n#{lib} is missing.  please visit http://nokogiri.org/tutorials/installing_nokogiri.html for help with installing dependencies.\n-----"
end

def have_iconv?
  have_header('iconv.h') or return false
  %w{ iconv_open libiconv_open }.any? do |method|
    have_func(method, 'iconv.h') or
      have_library('iconv', method, 'iconv.h')
  end
end

def each_iconv_idir
  # If --with-iconv-dir or --with-opt-dir is given, it should be
  # the first priority
  %w[iconv opt].each { |config|
    idir = preserving_globals {
      dir_config(config)
    }.first and yield idir
  }

  # Try the system default
  yield "/usr/include"

  cflags, = preserving_globals {
    pkg_config('libiconv')
  }
  if cflags
    cflags.shellsplit.each { |arg|
      arg.sub!(/\A-I/, '') and
      yield arg
    }
  end

  nil
end

def iconv_prefix
  # Make sure libxml2 is built with iconv
  each_iconv_idir { |idir|
    next unless File.file?(File.join(idir, 'iconv.h'))

    prefix, dir = File.split(idir)
    next unless dir == 'include'

    preserving_globals {
      # Follow the way libxml2's configure uses a value given with
      # --with-iconv[=DIR]
      $CPPFLAGS = "-I#{idir}".quote << ' ' << $CPPFLAGS
      $LIBPATH.unshift(File.join(prefix, "lib"))
      have_iconv?
    } and break prefix
  } or asplode "libiconv"
end

def process_recipe(name, version, static_p, cross_p)
  MiniPortile.new(name, version).tap do |recipe|
    recipe.target = portsdir = File.join(ROOT, "ports")
    # Prefer host_alias over host in order to use i586-mingw32msvc as
    # correct compiler prefix for cross build, but use host if not set.
    recipe.host = RbConfig::CONFIG["host_alias"].empty? ? RbConfig::CONFIG["host"] : RbConfig::CONFIG["host_alias"]
    recipe.patch_files = Dir[File.join(portsdir, "patches", name, "*.patch")].sort

    yield recipe

    env = Hash.new { |hash, key|
      hash[key] = "#{ENV[key]}"  # (ENV[key].dup rescue '')
    }

    recipe.configure_options.flatten!

    recipe.configure_options.delete_if { |option|
      case option.shellsplit.first
      when /\A(\w+)=(.*)\z/
        env[$1] = $2
        true
      else
        false
      end
    }

    if static_p
      recipe.configure_options += [
        "--disable-shared",
        "--enable-static",
      ]
      env['CFLAGS'] = "-fPIC #{env['CFLAGS']}"
    else
      recipe.configure_options += [
        "--enable-shared",
        "--disable-static",
      ]
    end

    if cross_p
      recipe.configure_options += [
        "--target=#{recipe.host}",
        "--host=#{recipe.host}",
      ]
    end

    if RbConfig::CONFIG['target_cpu'] == 'universal'
      %w[CFLAGS LDFLAGS].each { |key|
        unless env[key].shellsplit.include?('-arch')
          env[key] << ' ' << RbConfig::CONFIG['ARCH_FLAG']
        end
      }
    end

    recipe.configure_options += env.map { |key, value|
      "#{key}=#{value}".shellescape
    }

    if recipe.patch_files.empty?
      message! "Building #{name}-#{version} for nokogiri.\n"
    else
      message! "Building #{name}-#{version} for nokogiri with the following patches applied:\n"

      recipe.patch_files.each { |patch|
        message! "\t- %s\n" % File.basename(patch)
      }
    end

    message! <<-"EOS"
************************************************************************
IMPORTANT!  Nokogiri builds and uses a packaged version of #{name}.

If this is a concern for you and you want to use the system library
instead, abort this installation process and reinstall nokogiri as
follows:

    gem install nokogiri -- --use-system-libraries

If you are using Bundler, tell it to use the option:

    bundle config build.nokogiri --use-system-libraries
    bundle install
    EOS

    message! <<-"EOS" if name == 'libxml2'

However, note that nokogiri does not necessarily support all versions
of libxml2.

For example, libxml2-2.9.0 and higher are currently known to be broken
and thus unsupported by nokogiri, due to compatibility problems and
XPath optimization bugs.
    EOS

    message! <<-"EOS"
************************************************************************
    EOS

    checkpoint = "#{recipe.target}/#{recipe.name}-#{recipe.version}-#{recipe.host}.installed"
    unless File.exist?(checkpoint)
      recipe.cook
      FileUtils.touch checkpoint
    end
    recipe.activate
  end
end

def lib_a(ldflag)
  case ldflag
  when /\A-l(.+)/
    "lib#{$1}.#{$LIBEXT}"
  end
end

#
# monkey patches
#

# Workaround for Ruby bug #8074, introduced in Ruby 2.0.0, fixed in Ruby 2.1.0
# https://bugs.ruby-lang.org/issues/8074
@libdir_basename = "lib" if RUBY_VERSION < '2.1.0'

# Workaround for #1102
def monkey_patch_mini_portile
  MiniPortile.class_eval do
    def patch
      @patch_files.each do |full_path|
        next unless File.exists?(full_path)
        output "Running patch with #{full_path}..."
        execute('patch', %Q(patch -p1 < #{full_path}))
      end
    end
  end
end

#
# main
#

case
when arg_config('--help')
  do_help
when arg_config('--clean')
  do_clean
end

RbConfig::MAKEFILE_CONFIG['CC'] = ENV['CC'] if ENV['CC']

if defined?(RUBY_ENGINE) && RUBY_ENGINE == 'macruby'
  $LIBRUBYARG_STATIC.gsub!(/-static/, '')
end

$CFLAGS << " #{ENV["CFLAGS"]}"
$LIBS << " #{ENV["LIBS"]}"

case RbConfig::CONFIG['target_os']
when 'mingw32', /mswin/
  windows_p = true
  $CFLAGS << " -DXP_WIN -DXP_WIN32 -DUSE_INCLUDED_VASPRINTF"
when /solaris/
  $CFLAGS << " -DUSE_INCLUDED_VASPRINTF"
else
  $CFLAGS << " -g -DXP_UNIX"
end

if RUBY_PLATFORM =~ /mingw/i
  # Work around a character escaping bug in MSYS by passing an arbitrary
  # double quoted parameter to gcc. See https://sourceforge.net/p/mingw/bugs/2142
  $CPPFLAGS << ' "-Idummypath"'
end

if RbConfig::MAKEFILE_CONFIG['CC'] =~ /gcc/
  $CFLAGS << " -O3" unless $CFLAGS[/-O\d/]
  $CFLAGS << " -Wall -Wcast-qual -Wwrite-strings -Wconversion -Wmissing-noreturn -Winline"
end

  message! "Building nokogiri using system libraries.\n"

  dir_config('zlib')

  # Using system libraries means we rely on the system libxml2 with
  # regard to the iconv support.

  #dir_config('xml2').any?  or pkg_config('libxml-2.0')
  #dir_config('xslt').any?  or pkg_config('libxslt')
  #dir_config('exslt').any? or pkg_config('libexslt')

static_p = false
pkg_config('libxml-2.0')
pkg_config('libxslt')
pkg_config('libexslt')

  try_cpp(<<-SRC) or abort "libxml2 version 2.6.21 or later is required!"
#include <libxml/xmlversion.h>

#if LIBXML_VERSION < 20621
#error libxml2 is too old
#endif
  SRC

  try_cpp(<<-SRC) or warn "libxml2 version 2.9.0 and later is not yet supported, but proceeding anyway."
#include <libxml/xmlversion.h>

#if LIBXML_VERSION >= 20900
#error libxml2 is too new
#endif
  SRC

{
  "xml2"  => ['xmlParseDoc',            'libxml/parser.h'],
  "xslt"  => ['xsltParseStylesheetDoc', 'libxslt/xslt.h'],
  "exslt" => ['exsltFuncRegister',      'libexslt/exslt.h'],
}.each { |lib, (func, header)|
  have_func(func, header) ||
  have_library(lib, func, header) ||
  have_library("lib#{lib}", func, header) or
    asplode("lib#{lib}")
}

have_func('xmlHasFeature') or abort "xmlHasFeature() is missing."
have_func('xmlFirstElementChild')
have_func('xmlRelaxNGSetParserStructuredErrors')
have_func('xmlRelaxNGSetParserStructuredErrors')
have_func('xmlRelaxNGSetValidStructuredErrors')
have_func('xmlSchemaSetValidStructuredErrors')
have_func('xmlSchemaSetParserStructuredErrors')

if ENV['CPUPROFILE']
  unless find_library('profiler', 'ProfilerEnable', *LIB_DIRS)
    abort "google performance tools are not installed"
  end
end

create_makefile('nokogiri/nokogiri')

if enable_config('clean', true)
  # Do not clean if run in a development work tree.
  File.open('Makefile', 'at') { |mk|
    mk.print <<EOF
all: clean-ports

clean-ports: $(DLLIB)
	-$(Q)$(RUBY) $(srcdir)/extconf.rb --clean --#{static_p ? 'enable' : 'disable'}-static
EOF
  }
end

# :startdoc:
