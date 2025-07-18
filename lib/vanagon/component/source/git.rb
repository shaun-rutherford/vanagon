require 'vanagon/utilities'
require 'vanagon/errors'
require 'vanagon/logger'
# This stupid library requires a capital 'E' in its name
# but it provides a wealth of useful constants
require 'English'
require 'build/uri'
require 'git'
require 'logger'
require 'timeout'

class Vanagon
  class Component
    class Source
      class Git
        attr_accessor :url, :log_url, :ref, :workdir, :clone_options
        attr_reader :version, :default_options, :repo

        class << self
          # Attempt to connect to whatever URL is provided and
          # return true or false base on a number of guesses of whether it's a valid Git repo.
          #
          # @param url [#to_s] A URI::HTTPS, URI:HTTP, or String with the the URL of the
          #        remote git repository.
          # @param timeout [Number] Time (in seconds) to wait before assuming the
          #        git command has failed. Useful in instances where a URL
          #        prompts for credentials despite not being a git remote
          # @return [Boolean] whether #url is a valid Git repo or not
          def valid_remote?(url, timeout = 0)
            # RE-15209. To relieve github rate-limiting, if the URL starts with
            # https://github.com/... just accept it rather than ping github over and over.
            return github_remote?(url) if url.to_s.start_with?(github_url_prefix)

            begin
              # [RE-13837] there's a bug in Git.ls_remote that when ssh prints something like
              #  Warning: Permanently added 'github.com,192.30.255.113' (RSA)
              # Git.ls_remote attempts to parse it as actual git output and fails
              # with: NoMethodError: undefined method `split' for nil:NilClass
              #
              # Work around it by calling 'git ls-remote' directly ourselves.
              Timeout.timeout(timeout) do
                Vanagon::Utilities.local_command("git ls-remote --heads #{url} > /dev/null 2>&1", log: false)
                $?.exitstatus.zero?
              end
            rescue RuntimeError
              # Either a Timeout::Error or some other execution exception that we'll just call
              # 'invalid'
              false
            end
          end

          def github_url_prefix
            'https://github.com/'
          end

          def github_remote?(url)
            github_source_type(url) == :github_remote
          end

          # VANAGON-227 We need to be careful when guessing whether a https://github.com/...
          # URL is actually a true git repo. Make some rules around it based on the github API.
          # Decide that anything with a documented media_type is just an http url.
          # We do this instead of talking to GitHub directly to avoid rate limiting.
          # See:
          # https://docs.github.com/en/repositories/working-with-files/using-files/downloading-source-code-archives
          # https://docs.github.com/en/rest/repos/contents?apiVersion=2022-11-28#download-a-repository-archive-tar
          # https://docs.github.com/en/rest/repos/contents?apiVersion=2022-11-28#download-a-repository-archive-zip
          def github_source_type(url)
            url_directory = url.to_s.delete_prefix(github_url_prefix)
            url_components = url_directory.split('/')

            # Find cases of supported github media types.
            # [ owner, repo, media_type, ref ]
            path_types = ['archive', 'releases', 'tarball', 'zipball']
            if path_types.include?(url_components[2]) ||
               url_components[-1].end_with?('.tar.gz') ||
               url_components[-1].end_with?('.zip')
              :github_media
            else
              :github_remote
            end
          end
        end

        # Default options used when cloning; this may expand
        # or change over time.
        def default_options # rubocop:disable Lint/DuplicateMethods
          @default_options ||= { ref: "HEAD", config: ['submodule.recurse=true'] }
        end
        private :default_options

        # Constructor for the Git source type
        #
        # @param url [String] url of git repo to use as source
        # @param ref [String] ref to checkout from git repo
        # @param workdir [String] working directory to clone into
        def initialize(url, workdir:, **options) # rubocop:disable Metrics/AbcSize
          opts = default_options.merge(options.reject { |k, v| v.nil? })

          # Ensure that #url returns a URI object
          @url = Build::URI.parse(url.to_s)
          @log_url = @url.host + @url.path unless @url.host.nil? || @url.path.nil?
          @ref = opts[:ref]
          @dirname = opts[:dirname]
          @workdir = File.realpath(workdir)
          @clone_options = opts[:clone_options] ||= {}

          # We can test for Repo existence without cloning
          raise Vanagon::InvalidRepo, "\"#{url}\" is not a valid Git repo" unless valid_remote?
        end

        # Fetch the source. In this case, clone the repository into the workdir
        # and check out the ref. Also sets the version if there is a git tag as
        # a side effect.
        def fetch
          begin
            @clone ||= ::Git.open(File.join(workdir, dirname))
            @clone.fetch
          rescue ::Git::Error, ArgumentError
            clone!
          end
          checkout!
          version
        end

        # Return the correct incantation to cleanup the source directory for a given source
        #
        # @return [String] command to cleanup the source
        def cleanup
          "rm -rf #{dirname}"
        end

        # There is no md5 to manually verify here, so this is a noop.
        def verify
          # nothing to do here, so just tell users that and return
          VanagonLogger.info "Nothing to verify for '#{dirname}' (using Git reference '#{ref}')"
        end

        # The dirname to reference when building from the repo
        #
        # @return [String] the directory where the repo was cloned
        def dirname
          @dirname || File.basename(url.path, ".git")
        end

        # Use `git describe` to lazy-load a version for this component
        def version # rubocop:disable Lint/DuplicateMethods
          @version ||= describe
        end

        # Perform a git clone of @url as a lazy-loaded
        # accessor for @clone
        def clone
          if @clone_options.empty?
            @clone ||= ::Git.clone(url, dirname, path: workdir)
          else
            @clone ||= ::Git.clone(url, dirname, path: workdir, **clone_options)
          end
        end

        # Attempt to connect to whatever URL is provided and
        # return True or False depending on whether or not
        # `git` thinks it's a valid Git repo.
        #
        # @return [Boolean] whether #url is a valid Git repo or not
        def valid_remote?
          self.class.valid_remote? url
        end
        private :valid_remote?

        # Provide a list of remote refs (branches and tags)
        def remote_refs
          (remote['tags'].keys + remote['branches'].keys).uniq
        end
        private :remote_refs

        # Provide a list of local refs (branches and tags)
        def refs
          (clone.tags.map(&:name) + clone.branches.map(&:name)).uniq
        end
        private :refs

        # Clone a remote repo, make noise about it, and fail entirely
        # if we're unable to retrieve the remote repo
        def clone!
          VanagonLogger.info "Cloning Git repo '#{log_url}'"
          VanagonLogger.info "Successfully cloned '#{dirname}'" if clone
        rescue ::Git::Error
          raise Vanagon::InvalidRepo, "Unable to clone from '#{log_url}'"
        end
        private :clone!

        # Checkout desired ref/sha, make noise about it, and fail
        # entirely if we're unable to checkout that given ref/sha
        def checkout!
          VanagonLogger.info "Checking out '#{ref}' from Git repo '#{dirname}'"
          clone.checkout(ref)
        rescue ::Git::Error
          raise Vanagon::CheckoutFailed, "unable to checkout #{ref} from '#{log_url}'"
        end
        private :checkout!

        # Determines a version for the given directory based on the git describe
        # for the repository
        #
        # @return [String] The version of the directory according to git describe
        def describe
          clone.describe(ref, tags: true)
        rescue ::Git::Error
          VanagonLogger.info "Directory '#{dirname}' cannot be versioned by Git. Maybe it hasn't been tagged yet?"
        end
        private :describe
      end
    end
  end

  class GitError < Error; end
  # Raised when a URI is not a valid Source Control repo
  class InvalidRepo < GitError; end
  # Raised when checking out a given ref from a Git Repo fails
  class CheckoutFailed < GitError; end
end
