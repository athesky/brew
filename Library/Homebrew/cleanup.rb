# typed: false
# frozen_string_literal: true

require "utils/bottles"

require "formula"
require "cask/cask_loader"
require "set"

module Homebrew
  # Helper class for cleaning up the Homebrew cache.
  #
  # @api private
  class Cleanup
    CLEANUP_DEFAULT_DAYS = Homebrew::EnvConfig.cleanup_periodic_full_days.to_i.freeze
    private_constant :CLEANUP_DEFAULT_DAYS

    # {Pathname} refinement with helper functions for cleaning up files.
    module CleanupRefinement
      refine Pathname do
        def incomplete?
          extname.end_with?(".incomplete")
        end

        def nested_cache?
          directory? && %w[
            cargo_cache
            go_cache
            go_mod_cache
            glide_home
            java_cache
            npm_cache
            gclient_cache
          ].include?(basename.to_s)
        end

        def go_cache_directory?
          # Go makes its cache contents read-only to ensure cache integrity,
          # which makes sense but is something we need to undo for cleanup.
          directory? && %w[go_cache go_mod_cache].include?(basename.to_s)
        end

        def prune?(days)
          return false unless days
          return true if days.zero?

          return true if symlink? && !exist?

          days_ago = (DateTime.now - days).to_time
          mtime < days_ago && ctime < days_ago
        end

        def stale?(scrub: false)
          return false unless resolved_path.file?

          if dirname.basename.to_s == "Cask"
            stale_cask?(scrub)
          else
            stale_formula?(scrub)
          end
        end

        private

        def stale_formula?(scrub)
          return false unless HOMEBREW_CELLAR.directory?

          version = if HOMEBREW_BOTTLES_EXTNAME_REGEX.match?(to_s)
            begin
              Utils::Bottles.resolve_version(self)
            rescue
              nil
            end
          end

          version ||= basename.to_s[/\A.*(?:--.*?)*--(.*?)#{Regexp.escape(extname)}\Z/, 1]
          version ||= basename.to_s[/\A.*--?(.*?)#{Regexp.escape(extname)}\Z/, 1]

          return false unless version

          version = Version.new(version)

          return false unless (formula_name = basename.to_s[/\A(.*?)(?:--.*?)*--?(?:#{Regexp.escape(version)})/, 1])

          formula = begin
            Formulary.from_rack(HOMEBREW_CELLAR/formula_name)
          rescue FormulaUnavailableError, TapFormulaAmbiguityError, TapFormulaWithOldnameAmbiguityError
            nil
          end

          return false if formula.blank?

          resource_name = basename.to_s[/\A.*?--(.*?)--?(?:#{Regexp.escape(version)})/, 1]

          if resource_name == "patch"
            patch_hashes = formula.stable&.patches&.select(&:external?)&.map(&:resource)&.map(&:version)
            return true unless patch_hashes&.include?(Checksum.new(version.to_s))
          elsif resource_name && (resource_version = formula.stable&.resources&.dig(resource_name)&.version)
            return true if resource_version != version
          elsif version.is_a?(PkgVersion)
            return true if formula.pkg_version > version
          elsif formula.version > version
            return true
          end

          return true if scrub && !formula.latest_version_installed?

          return true if Utils::Bottles.file_outdated?(formula, self)

          false
        end

        def stale_cask?(scrub)
          return false unless (name = basename.to_s[/\A(.*?)--/, 1])

          cask = begin
            Cask::CaskLoader.load(name)
          rescue Cask::CaskError
            nil
          end

          return false if cask.blank?

          return true unless basename.to_s.match?(/\A#{Regexp.escape(name)}--#{Regexp.escape(cask.version)}\b/)

          return true if scrub && cask.versions.exclude?(cask.version)

          if cask.version.latest?
            cleanup_threshold = (DateTime.now - CLEANUP_DEFAULT_DAYS).to_time
            return mtime < cleanup_threshold && ctime < cleanup_threshold
          end

          false
        end
      end
    end

    using CleanupRefinement

    extend Predicable

    PERIODIC_CLEAN_FILE = (HOMEBREW_CACHE/".cleaned").freeze

    attr_predicate :dry_run?, :scrub?, :prune?
    attr_reader :args, :days, :cache, :disk_cleanup_size

    def initialize(*args, dry_run: false, scrub: false, days: nil, cache: HOMEBREW_CACHE)
      @disk_cleanup_size = 0
      @args = args
      @dry_run = dry_run
      @scrub = scrub
      @prune = days.present?
      @days = days || Homebrew::EnvConfig.cleanup_max_age_days.to_i
      @cache = cache
      @cleaned_up_paths = Set.new
    end

    def self.install_formula_clean!(f, dry_run: false)
      return if Homebrew::EnvConfig.no_install_cleanup?
      return unless f.latest_version_installed?
      return if skip_clean_formula?(f)

      if dry_run
        ohai "Would run `brew cleanup #{f}`"
      else
        ohai "Running `brew cleanup #{f}`..."
      end

      puts_no_install_cleanup_disable_message_if_not_already!
      return if dry_run

      Cleanup.new.cleanup_formula(f)
    end

    def self.puts_no_install_cleanup_disable_message
      return if Homebrew::EnvConfig.no_env_hints?
      return if Homebrew::EnvConfig.no_install_cleanup?

      puts "Disable this behaviour by setting HOMEBREW_NO_INSTALL_CLEANUP."
      puts "Hide these hints with HOMEBREW_NO_ENV_HINTS (see `man brew`)."
    end

    def self.puts_no_install_cleanup_disable_message_if_not_already!
      return if @puts_no_install_cleanup_disable_message_if_not_already

      puts_no_install_cleanup_disable_message
      @puts_no_install_cleanup_disable_message_if_not_already = true
    end

    def self.skip_clean_formula?(f)
      return false if Homebrew::EnvConfig.no_cleanup_formulae.blank?

      @skip_clean_formulae ||= Homebrew::EnvConfig.no_cleanup_formulae.split(",")
      @skip_clean_formulae.include?(f.name) || (@skip_clean_formulae & f.aliases).present?
    end

    def self.periodic_clean_due?
      return false if Homebrew::EnvConfig.no_install_cleanup?

      unless PERIODIC_CLEAN_FILE.exist?
        HOMEBREW_CACHE.mkpath
        FileUtils.touch PERIODIC_CLEAN_FILE
        return false
      end

      PERIODIC_CLEAN_FILE.mtime < (DateTime.now - CLEANUP_DEFAULT_DAYS).to_time
    end

    def self.periodic_clean!(dry_run: false)
      return if Homebrew::EnvConfig.no_install_cleanup?
      return unless periodic_clean_due?

      if dry_run
        oh1 "Would run `brew cleanup` which has not been run in the last #{CLEANUP_DEFAULT_DAYS} days"
      else
        oh1 "`brew cleanup` has not been run in the last #{CLEANUP_DEFAULT_DAYS} days, running now..."
      end

      puts_no_install_cleanup_disable_message
      return if dry_run

      Cleanup.new.clean!(quiet: true, periodic: true)
    end

    def clean!(quiet: false, periodic: false)
      if args.empty?
        Formula.installed
               .sort_by(&:name)
               .reject { |f| Cleanup.skip_clean_formula?(f) }
               .each do |formula|
          cleanup_formula(formula, quiet: quiet, ds_store: false, cache_db: false)
        end

        Cleanup.autoremove(dry_run: dry_run?) if Homebrew::EnvConfig.autoremove?

        cleanup_cache
        cleanup_logs
        cleanup_lockfiles
        cleanup_python_site_packages
        prune_prefix_symlinks_and_directories

        unless dry_run?
          cleanup_cache_db
          rm_ds_store
          HOMEBREW_CACHE.mkpath
          FileUtils.touch PERIODIC_CLEAN_FILE
        end

        # Cleaning up Ruby needs to be done last to avoid requiring additional
        # files afterwards. Additionally, don't allow it on periodic cleans to
        # avoid having to try to do a `brew install` when we've just deleted
        # the running Ruby process...
        return if periodic

        cleanup_portable_ruby
        cleanup_bootsnap
      else
        args.each do |arg|
          formula = begin
            Formulary.resolve(arg)
          rescue FormulaUnavailableError, TapFormulaAmbiguityError, TapFormulaWithOldnameAmbiguityError
            nil
          end

          cask = begin
            Cask::CaskLoader.load(arg)
          rescue Cask::CaskError
            nil
          end

          if formula && Cleanup.skip_clean_formula?(formula)
            onoe "Refusing to clean #{formula} because it is listed in " \
                 "#{Tty.bold}HOMEBREW_NO_CLEANUP_FORMULAE#{Tty.reset}!"
          elsif formula
            cleanup_formula(formula)
          end
          cleanup_cask(cask) if cask
        end
      end
    end

    def unremovable_kegs
      @unremovable_kegs ||= []
    end

    def cleanup_formula(formula, quiet: false, ds_store: true, cache_db: true)
      formula.eligible_kegs_for_cleanup(quiet: quiet)
             .each(&method(:cleanup_keg))
      cleanup_cache(Pathname.glob(cache/"#{formula.name}--*"))
      rm_ds_store([formula.rack]) if ds_store
      cleanup_cache_db(formula.rack) if cache_db
      cleanup_lockfiles(FormulaLock.new(formula.name).path)
    end

    def cleanup_cask(cask, ds_store: true)
      cleanup_cache(Pathname.glob(cache/"Cask/#{cask.token}--*"))
      rm_ds_store([cask.caskroom_path]) if ds_store
      cleanup_lockfiles(CaskLock.new(cask.token).path)
    end

    def cleanup_keg(keg)
      cleanup_path(keg) { keg.uninstall(raise_failures: true) }
    rescue Errno::EACCES, Errno::ENOTEMPTY => e
      opoo e.message
      unremovable_kegs << keg
    end

    def cleanup_logs
      return unless HOMEBREW_LOGS.directory?

      logs_days = [days, CLEANUP_DEFAULT_DAYS].min

      HOMEBREW_LOGS.subdirs.each do |dir|
        cleanup_path(dir) { dir.rmtree } if dir.prune?(logs_days)
      end
    end

    def cleanup_unreferenced_downloads
      return if dry_run?
      return unless (cache/"downloads").directory?

      downloads = (cache/"downloads").children

      referenced_downloads = [cache, cache/"Cask"].select(&:directory?)
                                                  .flat_map(&:children)
                                                  .select(&:symlink?)
                                                  .map(&:resolved_path)

      (downloads - referenced_downloads).each do |download|
        if download.incomplete?
          begin
            LockFile.new(download.basename).with_lock do
              download.unlink
            end
          rescue OperationInProgressError
            # Skip incomplete downloads which are still in progress.
            next
          end
        elsif download.directory?
          FileUtils.rm_rf download
        else
          download.unlink
        end
      end
    end

    def cleanup_cache(entries = nil)
      entries ||= [cache, cache/"Cask"].select(&:directory?).flat_map(&:children)

      entries.each do |path|
        next if path == PERIODIC_CLEAN_FILE

        FileUtils.chmod_R 0755, path if path.go_cache_directory? && !dry_run?
        next cleanup_path(path) { path.unlink } if path.incomplete?
        next cleanup_path(path) { FileUtils.rm_rf path } if path.nested_cache?

        if path.prune?(days)
          if path.file? || path.symlink?
            cleanup_path(path) { path.unlink }
          elsif path.directory? && path.to_s.include?("--")
            cleanup_path(path) { FileUtils.rm_rf path }
          end
          next
        end

        # If we've specified --prune don't do the (expensive) .stale? check.
        cleanup_path(path) { path.unlink } if !prune? && path.stale?(scrub: scrub?)
      end

      cleanup_unreferenced_downloads
    end

    def cleanup_path(path)
      return unless path.exist?
      return unless @cleaned_up_paths.add?(path)

      @disk_cleanup_size += path.disk_usage

      if dry_run?
        puts "Would remove: #{path} (#{path.abv})"
      else
        puts "Removing: #{path}... (#{path.abv})"
        yield
      end
    end

    def cleanup_lockfiles(*lockfiles)
      return if dry_run?

      lockfiles = HOMEBREW_LOCKS.children.select(&:file?) if lockfiles.empty? && HOMEBREW_LOCKS.directory?

      lockfiles.each do |file|
        next unless file.readable?
        next unless file.open(File::RDWR).flock(File::LOCK_EX | File::LOCK_NB)

        begin
          file.unlink
        ensure
          file.open(File::RDWR).flock(File::LOCK_UN) if file.exist?
        end
      end
    end

    def cleanup_portable_ruby
      vendor_dir = HOMEBREW_LIBRARY/"Homebrew/vendor"
      portable_ruby_latest_version = (vendor_dir/"portable-ruby-version").read.chomp

      portable_rubies_to_remove = []
      Pathname.glob(vendor_dir/"portable-ruby/*.*").select(&:directory?).each do |path|
        next if !use_system_ruby? && portable_ruby_latest_version == path.basename.to_s

        portable_rubies_to_remove << path
      end

      return if portable_rubies_to_remove.empty?

      bundler_path = vendor_dir/"bundle/ruby"
      if dry_run?
        puts Utils.popen_read("git", "-C", HOMEBREW_REPOSITORY, "clean", "-nx", bundler_path).chomp
      else
        puts Utils.popen_read("git", "-C", HOMEBREW_REPOSITORY, "clean", "-ffqx", bundler_path).chomp
      end

      portable_rubies_to_remove.each do |portable_ruby|
        cleanup_path(portable_ruby) { portable_ruby.rmtree }
      end
    end

    def use_system_ruby?; end

    def cleanup_bootsnap
      bootsnap = cache/"bootsnap"
      return unless bootsnap.exist?

      cleanup_path(bootsnap) { bootsnap.rmtree }
    end

    def cleanup_cache_db(rack = nil)
      FileUtils.rm_rf [
        cache/"desc_cache.json",
        cache/"linkage.db",
        cache/"linkage.db.db",
      ]

      CacheStoreDatabase.use(:linkage) do |db|
        break unless db.created?

        db.each_key do |keg|
          next if rack.present? && !keg.start_with?("#{rack}/")
          next if File.directory?(keg)

          LinkageCacheStore.new(keg, db).delete!
        end
      end
    end

    def rm_ds_store(dirs = nil)
      dirs ||= Keg::MUST_EXIST_DIRECTORIES + [
        HOMEBREW_PREFIX/"Caskroom",
      ]
      dirs.select(&:directory?)
          .flat_map { |d| Pathname.glob("#{d}/**/.DS_Store") }
          .each do |dir|
            dir.unlink
          rescue Errno::EACCES
            # don't care if we can't delete a .DS_Store
            nil
          end
    end

    def cleanup_python_site_packages
      pyc_files = Hash.new { |h, k| h[k] = [] }
      seen_non_pyc_file = Hash.new { |h, k| h[k] = false }
      unused_pyc_files = []

      HOMEBREW_PREFIX.glob("lib/python*/site-packages").each do |site_packages|
        site_packages.each_child do |child|
          next unless child.directory?
          # TODO: Work out a sensible way to clean up pip's, setuptools', and wheel's
          #       {dist,site}-info directories. Alternatively, consider always removing
          #       all `-info` directories, because we may not be making use of them.
          next if child.basename.to_s.end_with?("-info")

          # Clean up old *.pyc files in the top-level __pycache__.
          if child.basename.to_s == "__pycache__"
            child.find do |path|
              next unless path.extname == ".pyc"
              next unless path.prune?(days)

              unused_pyc_files << path
            end

            next
          end

          # Look for directories that contain only *.pyc files.
          child.find do |path|
            next if path.directory?

            if path.extname == ".pyc"
              pyc_files[child] << path
            else
              seen_non_pyc_file[child] = true
              break
            end
          end
        end
      end

      unused_pyc_files += pyc_files.reject { |k,| seen_non_pyc_file[k] }
                                   .values
                                   .flatten
      return if unused_pyc_files.blank?

      unused_pyc_files.each do |pyc|
        cleanup_path(pyc) { pyc.unlink }
      end
    end

    def prune_prefix_symlinks_and_directories
      ObserverPathnameExtension.reset_counts!

      dirs = []

      Keg::MUST_EXIST_SUBDIRECTORIES.each do |dir|
        next unless dir.directory?

        dir.find do |path|
          path.extend(ObserverPathnameExtension)
          if path.symlink?
            unless path.resolved_path_exists?
              path.uninstall_info if path.to_s.match?(Keg::INFOFILE_RX) && !dry_run?

              if dry_run?
                puts "Would remove (broken link): #{path}"
              else
                path.unlink
              end
            end
          elsif path.directory? && Keg::MUST_EXIST_SUBDIRECTORIES.exclude?(path)
            dirs << path
          end
        end
      end

      dirs.reverse_each do |d|
        if dry_run? && d.children.empty?
          puts "Would remove (empty directory): #{d}"
        else
          d.rmdir_if_possible
        end
      end

      return if dry_run?

      return if ObserverPathnameExtension.total.zero?

      n, d = ObserverPathnameExtension.counts
      print "Pruned #{n} symbolic links "
      print "and #{d} directories " if d.positive?
      puts "from #{HOMEBREW_PREFIX}"
    end

    def self.autoremove(dry_run: false)
      require "utils/autoremove"
      require "cask/caskroom"

      # If this runs after install, uninstall, reinstall or upgrade,
      # the cache of installed formulae may no longer be valid.
      Formula.clear_cache unless dry_run

      formulae = Formula.installed
      # Remove formulae listed in HOMEBREW_NO_CLEANUP_FORMULAE and their dependencies.
      if Homebrew::EnvConfig.no_cleanup_formulae.present?
        formulae -= formulae.select(&method(:skip_clean_formula?))
                            .flat_map { |f| [f, *f.runtime_formula_dependencies] }
      end
      casks = Cask::Caskroom.casks

      removable_formulae = Utils::Autoremove.removable_formulae(formulae, casks)

      return if removable_formulae.blank?

      formulae_names = removable_formulae.map(&:full_name).sort

      verb = dry_run ? "Would autoremove" : "Autoremoving"
      oh1 "#{verb} #{formulae_names.count} unneeded #{Utils.pluralize("formula", formulae_names.count, plural: "e")}:"
      puts formulae_names.join("\n")
      return if dry_run

      require "uninstall"

      kegs_by_rack = removable_formulae.map(&:any_installed_keg).group_by(&:rack)
      Uninstall.uninstall_kegs(kegs_by_rack)

      # The installed formula cache will be invalid after uninstalling.
      Formula.clear_cache
    end
  end
end

require "extend/os/cleanup"
