require 'optparse'
require 'pp'

module Svn2Git
  DEFAULT_AUTHORS_FILE = "~/.svn2git/authors"

  class Migration

    attr_reader :dir

    def initialize(args)
      @options = parse(args)
      show_help_message("Missing SVN_URL parameter") if args.empty?
      show_help_message('Too many arguments') if args.size > 1

      @url = args.first
    end

    def run!
      clone!
      fix_tags
      fix_branches
      fix_trunk
      optimize_repos
    end

    def parse(args)
      # Set up reasonable defaults for options.
      options = {}
      options[:continue] = false
      options[:verbose] = false
      options[:rootistrunk] = false
      options[:trunk] = 'trunk'
      options[:branches] = 'branches'
      options[:tags] = 'tags'
      options[:exclude] = []

      if File.exists?(File.expand_path(DEFAULT_AUTHORS_FILE))
        options[:authors] = DEFAULT_AUTHORS_FILE
      end


      # Parse the command-line arguments.
      @opts = OptionParser.new do |opts|
        opts.banner = 'Usage: svn2git SVN_URL [options]'

        opts.separator ''
        opts.separator 'Specific options:'

        opts.on('--trunk TRUNK_PATH', 'Subpath to trunk from repository URL (default: trunk)') do |trunk|
          options[:trunk] = trunk
        end

        opts.on('--branches BRANCHES_PATH', 'Subpath to branches from repository URL (default: branches)') do |branches|
          options[:branches] = branches
        end
        opts.on('--tags TAGS_PATH', 'Subpath to tags from repository URL (default: tags)') do |tags|
          options[:tags] = tags
        end

        opts.on('--rootistrunk', 'Use this if the root level of the repo is equivalent to the trunk and there are no tags or branches') do
          options[:rootistrunk] = true
          options[:trunk] = nil
          options[:branches] = nil
          options[:tags] = nil
        end

        opts.on('--notrunk', 'Do not import anything from trunk') do
          options[:trunk] = nil
        end

        opts.on('--nobranches', 'Do not try to import any branches') do
          options[:branches] = nil
        end

        opts.on('--notags', 'Do not try to import any tags') do
          options[:tags] = nil
        end

        opts.on('--authors AUTHORS_FILE', "Path to file containing svn-to-git authors mapping (default: #{DEFAULT_AUTHORS_FILE})") do |authors|
          options[:authors] = authors
        end

        opts.on('--exclude REGEX', 'Specify a Perl regular expression to filter paths when fetching; can be used multiple times') do |regex|
          options[:exclude] << regex
        end

        opts.on('-v', '--verbose', 'Be verbose in logging -- useful for debugging issues') do
          options[:verbose] = true
        end
           
        opts.on('-c', '--continue', 'In case your git svn fetch failed, re-run with this options, it will bypass the init phase') do
          options[:continue] = true
        end    
        
        opts.separator ""

        # No argument, shows at tail.  This will print an options summary.
        # Try it and see!
        opts.on_tail('-h', '--help', 'Show this message') do
          puts opts
          exit
        end
      end

      @opts.parse! args
      options
    end

  private

    def clone!
      trunk = @options[:trunk]
      branches = @options[:branches]
      tags = @options[:tags]
      rootistrunk = @options[:rootistrunk]
      authors = @options[:authors]
      exclude = @options[:exclude]
      continue = @options[:continue]
      
      if continue
        puts "Trying to continue previous run : bypassing git init\n\n"
      else
        if rootistrunk
          # Non-standard repository layout.  The repository root is effectively 'trunk.'
          run_command("git svn init --no-metadata --trunk=#{@url}")

        else
          cmd = "git svn init --no-metadata "

          # Add each component to the command that was passed as an argument.
          cmd += "--trunk=#{trunk} " unless trunk.nil?
          cmd += "--tags=#{tags} " unless tags.nil?
          cmd += "--branches=#{branches} " unless branches.nil?

          cmd += @url

          run_command(cmd)
        end
      end
      run_command("git config svn.authorsfile #{authors}") unless authors.nil?

      cmd = "git svn fetch"
      unless exclude.empty?
        # Add exclude paths to the command line; some versions of git support
        # this for fetch only, later also for init.
        regex = []
        unless rootistrunk
          regex << "#{trunk}[/]" unless trunk.nil?
          regex << "#{tags}[/][^/]+[/]" unless tags.nil?
          regex << "#{branches}[/][^/]+[/]" unless branches.nil?
        end
        regex = '^(?:' + regex.join('|') + ')(?:' + exclude.join('|') + ')'
        cmd += "'--ignore-paths=#{regex}'"
      end
      run_command(cmd)

      get_branches
    end

    def get_branches
      @local = run_command("git branch -l").split(/\n/).collect{ |b| b.strip }
      @remote = run_command("git branch -r").split(/\n/).collect{ |b| b.strip }
      @tags = @remote.find_all { |b| b.strip =~ %r{^tags\/} }
    end

    def fix_tags
      @tags.each do |tag|
        tag = tag.strip
        id = tag.strip.gsub(%r{^tags\/}, '').strip
        subject = run_command("git log -1 --pretty=format:'%s' #{tag}")
        date = run_command("git log -1 --pretty=format:'%ci' #{tag}")
        run_command("GIT_COMMITTER_DATE='#{date}' git tag -a -m '#{subject}' '#{id}' '#{tag}'")
        run_command("git branch -d -r #{tag}")
      end
    end

    def fix_branches
      svn_branches = @remote.find_all { |b| not @tags.include?(b) }
      svn_branches.each do |branch|
        branch = branch.strip
        next if branch == 'trunk'

        run_command("git checkout #{branch}")
        run_command("git checkout -b #{branch}")    
      end
    end

    def fix_trunk
      trunk = @remote.find { |b| b.strip == 'trunk' }
      if trunk
        run_command("git checkout trunk")
        run_command("git branch -D master")
        run_command("git checkout -f -b master")
        run_command("git branch -d -r trunk")
      end
    end

    def optimize_repos
      run_command("git gc")
    end

    def run_command(cmd)
      log "Running command: #{cmd}"

      ret = ''

      IO.popen(cmd) do |stdout|
        stdout.each do |line|
          log line
          ret << line
        end
      end
      
      ret
    end

    def log(msg)
      puts msg if @options[:verbose]
    end

    def show_help_message(msg)
      puts "Error starting script: #{msg}\n\n"
      puts @opts.help
      exit
    end

  end
end

