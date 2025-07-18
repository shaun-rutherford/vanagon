class Vanagon
  class Platform
    class OSX < Vanagon::Platform
      # Because homebrew does not support being run by root
      # we need to have this method to run it in the context of another user
      #
      # @param build_dependencies [Array] list of all build dependencies to install
      # @return [String] a command to install all of the build dependencies
      def install_build_dependencies(list_build_dependencies)
        <<-HERE.undent
          mkdir -p /etc/homebrew
          cd /etc/homebrew
          sudo su test -c '#{@brew} install #{list_build_dependencies.join(' ')}'
        HERE
      end

      # The specific bits used to generate a osx package for a given project
      #
      # @param project [Vanagon::Project] project to build a osx package of
      # @return [Array] list of commands required to build a osx package for the given project from a tarball
      def generate_package(project) # rubocop:disable Metrics/AbcSize,Metrics/PerceivedComplexity
        target_dir = project.repo ? output_dir(project.repo) : output_dir

        # Here we maintain backward compatibility with older vanagon versions
        # that did this by default.  This shim should get removed at some point
        # in favor of just letting the makefile deliver the bill-of-materials
        # to the correct directory. This shouldn't be required at all then.
        if project.bill_of_materials.nil?
          bom_install = [
            # Move bill-of-materials into a docdir
            "mkdir -p $(tempdir)/osx/build/root/#{project.name}-#{project.version}/usr/local/share/doc/#{project.name}",
            "mv $(tempdir)/osx/build/root/#{project.name}-#{project.version}/bill-of-materials $(tempdir)/osx/build/root/#{project.name}-#{project.version}/usr/local/share/doc/#{project.name}/bill-of-materials",
          ]
        else
          bom_install = []
        end

        # Previously, the "commands" method would test if it could SSH to the signer node and just skip
        # all the signing stuff if it couldn't and VANAGON_FORCE_SIGNING was not set. It never really tested
        # that signing actually worked and skipped it if it didn't. Now with the local commands, we really
        # can't even do that test. So just don't even try signing unless VANAGON_FORCE_SIGNING is set.
        unlock = 'security unlock-keychain -p $$SIGNING_KEYCHAIN_PW $$SIGNING_KEYCHAIN'
        extra_sign_commands = []
        sign_files_commands = []
        # If we're not signing, move the pkg to the right place
        sign_package_commands = ["mv $(tempdir)/osx/build/#{project.name}-#{project.version}-#{project.release}-installer.pkg $(tempdir)/osx/build/pkg/"]
        sign_dmg_commands = []
        notarize_dmg_commands = []
        if ENV['VANAGON_FORCE_SIGNING']
          # You should no longer really need to do this, but it's here just in case.
          if project.extra_files_to_sign.any?
            method = project.use_local_signing ? 'local_commands' : 'commands'
            extra_sign_commands = Vanagon::Utilities::ExtraFilesSigner.send(method, project, @mktemp, "/osx/build/root/#{project.name}-#{project.version}")
          end

          # As of MacOS 15, we have to notarize the dmg. In order to get notarization, we have to
          # code sign every single binary, .bundle, and .dylib file in the package. So instead of
          # only signing a few files we specify, sign everything we can find that needs to be signed.
          # We then need to notarize the resulting dmg.
          #
          # This requires the VM to have the following env vars set in advance.
          #   SIGNING_KEYCHAIN - the name of the keychain containing the code/installer signing identities
          #   SIGNING_KEYCHAIN_PW - the password to unlock the keychain
          #   APPLICATION_SIGNING_CERT - the identity description used for application signing
          #   INSTALLER_SIGNING_CERT - the identity description used for installer .pkg signing
          #   NOTARY_PROFILE - The name of the notary profile stored in the keychain

          paths_with_binaries = {
            "root/#{project.name}-#{project.version}/opt/puppetlabs/bin/" => '*',
            "root/#{project.name}-#{project.version}/opt/puppetlabs/puppet/bin/" => '*',
            "root/#{project.name}-#{project.version}/opt/puppetlabs/puppet/lib/ruby/vendor_gems/bin" => '*',
            "root/#{project.name}-#{project.version}/opt/puppetlabs/puppet/lib/" => '*.dylib',
            "root/#{project.name}-#{project.version}/opt/puppetlabs/puppet/lib" => '*.bundle',
            'plugins' => 'puppet-agent-installer-plugin',
          }

          sign_files_commands = [unlock]
          sign_files_commands += paths_with_binaries.map do |path, name|
            "find $(tempdir)/osx/build/#{path} -name '#{name}' -type f -exec codesign --timestamp --options runtime --keychain $$SIGNING_KEYCHAIN -vfs \"$$APPLICATION_SIGNING_CERT\" {} \\;"
          end
          sign_files_commands += paths_with_binaries.map do |path, name|
            "find $(tempdir)/osx/build/#{path} -name '#{name}' -type f -exec codesign --verify --strict --verbose=2 {} \\;"
          end

          sign_package_commands = [
            unlock,
            "productsign --keychain $$SIGNING_KEYCHAIN --sign \"$$INSTALLER_SIGNING_CERT\" $(tempdir)/osx/build/#{project.name}-#{project.version}-#{project.release}-installer.pkg $(tempdir)/osx/build/pkg/#{project.name}-#{project.version}-#{project.release}-installer.pkg",
            "rm $(tempdir)/osx/build/#{project.name}-#{project.version}-#{project.release}-installer.pkg",
          ]

          dmg = "$(tempdir)/osx/build/dmg/#{project.package_name}"
          sign_dmg_commands = [
            unlock,
            'cd $(tempdir)/osx/build',
            "codesign --timestamp --keychain $$SIGNING_KEYCHAIN --sign \"$$APPLICATION_SIGNING_CERT\" #{dmg}",
            "codesign --verify --strict --verbose=2 #{dmg}",
          ]

          notarize_dmg_commands = ENV['NO_NOTARIZE'] ? [] : [
            unlock,
            "xcrun notarytool submit #{dmg} --keychain-profile \"$$NOTARY_PROFILE\" --wait",
            "xcrun stapler staple #{dmg}",
            "spctl --assess --type install --verbose #{dmg}"
          ]
        end

         # Setup build directories
        [
          "bash -c 'mkdir -p $(tempdir)/osx/build/{dmg,pkg,scripts,resources,root,payload,plugins}'",
          "mkdir -p $(tempdir)/osx/build/root/#{project.name}-#{project.version}",
          "mkdir -p $(tempdir)/osx/build/pkg",
          # Grab distribution xml, scripts and other external resources
          "cp #{project.name}-installer.xml $(tempdir)/osx/build/",
          #copy the uninstaller to the pkg dir, where eventually the installer will go too
          "cp #{project.name}-uninstaller.tool $(tempdir)/osx/build/pkg/",
          "cp scripts/* $(tempdir)/osx/build/scripts/",
          "if [ -d resources/osx/productbuild ] ; then cp -r resources/osx/productbuild/* $(tempdir)/osx/build/; fi",
          # Unpack the project
          "gunzip -c #{project.name}-#{project.version}.tar.gz | '#{@tar}' -C '$(tempdir)/osx/build/root/#{project.name}-#{project.version}' --strip-components 1 -xf -",

          bom_install,

          # Sign extra files
          extra_sign_commands,

          # Sign all binaries
          sign_files_commands,

          # Package the project
          "(cd $(tempdir)/osx/build/; #{@pkgbuild} --root root/#{project.name}-#{project.version} \
            --scripts $(tempdir)/osx/build/scripts \
            --identifier #{project.identifier}.#{project.name} \
            --version #{project.version} \
            --preserve-xattr \
            --install-location / \
            payload/#{project.name}-#{project.version}-#{project.release}.pkg)",

          # Create a custom installer using the pkg above
          "(cd $(tempdir)/osx/build/; #{@productbuild} --distribution #{project.name}-installer.xml \
            --identifier #{project.identifier}.#{project.name}-installer \
            --package-path payload/ \
            --resources $(tempdir)/osx/build/resources  \
            --plugins $(tempdir)/osx/build/plugins  \
            #{project.name}-#{project.version}-#{project.release}-installer.pkg)",

          sign_package_commands,

          # Create a dmg and ship it to the output directory
          "(cd $(tempdir)/osx/build; \
            #{@hdiutil} create \
              -volname #{project.name}-#{project.version} \
              -fs JHFS+ \
              -format UDBZ \
              -srcfolder pkg \
              dmg/#{project.package_name})",

          sign_dmg_commands,
          notarize_dmg_commands,
          "mkdir -p output/#{target_dir}",
          "cp $(tempdir)/osx/build/dmg/#{project.package_name} ./output/#{target_dir}"
        ].flatten.compact
      end

      # Method to generate the files required to build a osx package for the project
      #
      # @param workdir [String] working directory to stage the evaluated templates in
      # @param name [String] name of the project
      # @param binding [Binding] binding to use in evaluating the packaging templates
      # @param project [Vanagon::Project] Vanagon::Project we are building for
      def generate_packaging_artifacts(workdir, name, binding, project) # rubocop:disable Metrics/AbcSize
        resources_dir = File.join(workdir, "resources", "osx")
        FileUtils.mkdir_p(resources_dir)
        script_dir = File.join(workdir, "scripts")
        FileUtils.mkdir_p(script_dir)

        erb_file(File.join(VANAGON_ROOT, "resources/osx/project-installer.xml.erb"), File.join(workdir, "#{name}-installer.xml"), false, { :binding => binding })

        ["postinstall", "preinstall"].each do |script_file|
          erb_file(File.join(VANAGON_ROOT, "resources/osx/#{script_file}.erb"), File.join(script_dir, script_file), false, { :binding => binding })
          FileUtils.chmod 0755, File.join(script_dir, script_file)
        end

        erb_file(File.join(VANAGON_ROOT, 'resources', 'osx', 'uninstaller.tool.erb'), File.join(workdir, "#{name}-uninstaller.tool"), false, { :binding => binding })
        FileUtils.chmod 0755, File.join(workdir, "#{name}-uninstaller.tool")

        # Probably a better way to do this, but OSX tends to need some extra stuff
        FileUtils.cp_r("resources/osx/.", resources_dir) if File.exist?("resources/osx/")
      end

      # Method to derive the package name for the project
      #
      # @param project [Vanagon::Project] project to name
      # @return [String] name of the osx package for this project
      def package_name(project)
        "#{project.name}-#{project.version}-#{project.release}.#{@os_name}#{@os_version}.dmg"
      end

      # Constructor. Sets up some defaults for the osx platform and calls the parent constructor
      #
      # @param name [String] name of the platform
      # @return [Vanagon::Platform::OSX] the osx derived platform with the given name
      def initialize(name)
        @name = name
        @make = "/usr/bin/make"
        @tar = "tar"
        @shasum = "/usr/bin/shasum"
        @pkgbuild = "/usr/bin/pkgbuild"
        @productbuild = "/usr/bin/productbuild"
        @hdiutil = "/usr/bin/hdiutil"
        @patch = "/usr/bin/patch"
        @num_cores = "/usr/sbin/sysctl -n hw.physicalcpu"
        @mktemp = "mktemp -d -t 'tmp'"
        @brew = '/usr/local/bin/brew'
        super
      end
    end
  end
end
