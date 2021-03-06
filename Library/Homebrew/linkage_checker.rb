require "keg"
require "formula"

class LinkageChecker
  attr_reader :keg, :formula
  attr_reader :brewed_dylibs, :system_dylibs, :broken_dylibs, :broken_deps, :variable_dylibs
  attr_reader :undeclared_deps, :unnecessary_deps, :reverse_links
  attr_reader :unwanted_system_dylibs

  def initialize(keg, formula = nil)
    @keg = keg
    @formula = formula || resolve_formula(keg)
    @brewed_dylibs = Hash.new { |h, k| h[k] = Set.new }
    @system_dylibs = Set.new
    @broken_dylibs = []
    @broken_deps = Hash.new { |h, k| h[k] = [] }
    @variable_dylibs = Set.new
    @indirect_deps = []
    @undeclared_deps = []
    @reverse_links = Hash.new { |h, k| h[k] = Set.new }
    @unnecessary_deps = []
    @unwanted_system_dylibs = Set.new
    check_dylibs
  end

  def dylib_to_dep(dylib)
    dylib =~ %r{#{Regexp.escape(HOMEBREW_PREFIX)}/(opt|Cellar)/([\w+-.@]+)/}
    Regexp.last_match(2)
  end

  def check_dylibs
    checked_dylibs = Set.new
    @keg.find do |file|
      next if file.symlink? || file.directory?
      next unless file.dylib? || file.binary_executable? || file.mach_o_bundle?

      # weakly loaded dylibs may not actually exist on disk, so skip them
      # when checking for broken linkage
      file.dynamically_linked_libraries(except: :LC_LOAD_WEAK_DYLIB).each do |dylib|
        @reverse_links[dylib] << file
        next if checked_dylibs.include? dylib
        if dylib.start_with? "@"
          @variable_dylibs << dylib
        else
          begin
            owner = Keg.for Pathname.new(dylib)
          rescue NotAKegError
            @system_dylibs << dylib
          rescue Errno::ENOENT
            next if harmless_broken_link?(dylib)
            if (dep = dylib_to_dep(dylib))
              @broken_deps[dep] |= [dylib]
            else
              @broken_dylibs << dylib
            end
          else
            tap = Tab.for_keg(owner).tap
            f = if tap.nil? || tap.core_tap?
              owner.name
            else
              "#{tap}/#{owner.name}"
            end
            @brewed_dylibs[f] << dylib
          end
        end
        checked_dylibs << dylib
      end

      next unless OS.linux?
      system_whitelist = %w[
        ld-linux-x86-64.so.2
        libc.so.6
        libcrypt.so.1
        libdl.so.2
        libm.so.6
        libnsl.so.1
        libpthread.so.0
        libresolv.so.2
        librt.so.1
        libutil.so.1

        libgcc_s.so.1
        libgomp.so.1
        libstdc++.so.6
      ]
      system_sonames = @system_dylibs.to_a.map { |s| File.basename s }
      @unwanted_system_dylibs += system_sonames - system_whitelist
    end

    @indirect_deps, @undeclared_deps, @unnecessary_deps = check_undeclared_deps if formula
    @undeclared_deps -= ["gcc", "glibc"] if OS.linux?
  end

  def check_undeclared_deps
    filter_out = proc do |dep|
      next true if dep.build?
      next false unless dep.optional? || dep.recommended?
      formula.build.without?(dep)
    end
    declared_deps = formula.deps.reject { |dep| filter_out.call(dep) }.map(&:name)
    runtime_deps = keg.to_formula.runtime_dependencies(read_from_tab: false)
    recursive_deps = runtime_deps.map { |dep| dep.to_formula.name }
    declared_dep_names = declared_deps.map { |dep| dep.split("/").last }
    indirect_deps = []
    undeclared_deps = []
    @brewed_dylibs.each_key do |full_name|
      name = full_name.split("/").last
      next if name == formula.name
      if recursive_deps.include?(name)
        indirect_deps << full_name unless declared_dep_names.include?(name)
      else
        undeclared_deps << full_name
      end
    end
    sort_by_formula_full_name!(indirect_deps)
    sort_by_formula_full_name!(undeclared_deps)
    unnecessary_deps = declared_dep_names.reject do |full_name|
      name = full_name.split("/").last
      next true if Formula[name].bin.directory?
      @brewed_dylibs.keys.map { |x| x.split("/").last }.include?(name)
    end
    missing_deps = @broken_deps.values.flatten.map { |d| dylib_to_dep(d) }
    unnecessary_deps -= missing_deps
    [indirect_deps, undeclared_deps, unnecessary_deps]
  end

  def sort_by_formula_full_name!(arr)
    arr.sort! do |a, b|
      if a.include?("/") && !b.include?("/")
        1
      elsif !a.include?("/") && b.include?("/")
        -1
      else
        a <=> b
      end
    end
  end

  def display_normal_output
    display_items "System libraries", @system_dylibs
    display_items "Homebrew libraries", @brewed_dylibs
    display_items "Indirect dependencies with linkage", @indirect_deps
    display_items "Variable-referenced libraries", @variable_dylibs
    display_items "Missing libraries", @broken_dylibs
    display_items "Broken dependencies", @broken_deps
    display_items "Undeclared dependencies with linkage", @undeclared_deps
    display_items "Dependencies with no linkage", @unnecessary_deps
  end

  def display_reverse_output
    return if @reverse_links.empty?
    sorted = @reverse_links.sort
    sorted.each do |dylib, files|
      puts dylib
      files.each do |f|
        unprefixed = f.to_s.strip_prefix "#{@keg}/"
        puts "  #{unprefixed}"
      end
      puts unless dylib == sorted.last[0]
    end
  end

  def display_test_output
    display_items "System libraries", @system_dylibs if OS.linux?
    display_items "Missing libraries", @broken_dylibs
    display_items "Broken dependencies", @broken_deps
    display_items "Dependencies with no linkage", @unnecessary_deps
    puts "No broken dylib links" if @broken_dylibs.empty?
    return unless OS.linux?
    display_items "Unwanted system libraries", @unwanted_system_dylibs
    puts "No unwanted system libraries" if @unwanted_system_dylibs.empty?
  end

  def broken_dylibs?
    !@broken_dylibs.empty?
  end

  def undeclared_deps?
    !@undeclared_deps.empty?
  end

  def unnecessary_deps?
    !@unnecessary_deps.empty?
  end

  def unwanted_system_dylibs?
    !@unwanted_system_dylibs.empty?
  end

  private

  # Whether or not dylib is a harmless broken link, meaning that it's
  # okay to skip (and not report) as broken.
  def harmless_broken_link?(dylib)
    # libgcc_s_* is referenced by programs that use the Java Service Wrapper,
    # and is harmless on x86(_64) machines
    [
      "/usr/lib/libgcc_s_ppc64.1.dylib",
      "/opt/local/lib/libgcc/libgcc_s.1.dylib",
    ].include?(dylib)
  end

  # Display a list of things.
  # Things may either be an array, or a hash of (label -> array)
  def display_items(label, things)
    return if things.empty?
    puts "#{label}:"
    if things.is_a? Hash
      things.keys.sort.each do |list_label|
        things[list_label].sort.each do |item|
          puts "  #{item} (#{list_label})"
        end
      end
    else
      things.sort.each do |item|
        puts "  #{item}"
      end
    end
  end

  def resolve_formula(keg)
    Formulary.from_keg(keg)
  rescue FormulaUnavailableError
    opoo "Formula unavailable: #{keg.name}"
  end
end
