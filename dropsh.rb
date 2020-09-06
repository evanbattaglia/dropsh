#!/usr/bin/env ruby

require 'readline'
require 'shellwords'
require 'set'
require 'tempfile'

class String
  def red;            "\e[31m#{self}\e[0m" end
  def blue;           "\e[34m#{self}\e[0m" end
  def bold;           "\e[1m#{self}\e[22m" end
end

class DirListing
  attr_reader :directories, :file_sizes

  def initialize(raw)
    @raw = raw
    @directories = Set.new
    @file_sizes = {}
    lines = raw.split("\n")
    unless lines.first =~ /^ > Listing ".*"\.\.\. DONE$/
      raise "First line out dropbox_uploader.sh output unrecognized:\n#{raw}"
    end

    lines[1..].each do |line|
      if line =~ /^ \[([DF])\] ([0-9]{0,30}) *([^ ].*)$/
        if $1 == 'D'
          @directories << $3
        else
          @file_sizes[$3] = $2.to_i
        end
      else
        raise "Could not parse dropbox_uploader.sh output:\n#{raw}"
      end
    end
  end

  def exists?(filename)
    is_dir?(filename) || @file_sizes[filename]
  end

  def is_dir?(filename)
    @directories.include?(filename)
  end

  def files
    @files ||= Set.new(file_sizes.keys)
  end

  def to_s
    @raw
  end
end

module DropboxUploader
  module_function
  def command_output(*args)
    args = [args].flatten
    cmdline = ["dropbox_uploader.sh", *args].map{|arg| Shellwords.shellescape(arg)}.join(" ")
    `#{cmdline}`
  end
end

class DirTree
  def initialize
    @listings = {}
  end

  def listing(path)
    fresh_listing(path) unless @listings[path]
    @listings[path]
  end

  def fresh_listing(path)
    # TODO -- file not found
    # TODO -- file, not dir
    # probably make those errors in DirListing? or should check output code of dropbox_uploader.sh?
    @listings[path] = DirListing.new(DropboxUploader.command_output('list', path))
  end

  def clear_listing(path)
    @listings.delete path
  end

  def is_dir?(path)
    listing(File.dirname(path)).is_dir?(File.basename(path))
  end

  def exists?(path)
    listing(File.dirname(path)).exists?(File.basename(path))
  end
end

module TabCompletion
  module_function
  def complete(dirtree, cwd, word)
    # TODO: not sure if will use word or not. it seems to be just the last thing,
    # we need the whole line buffer here to see position
    cmdline = Readline.line_buffer
    cmd, *argv = Shellwords.shellsplit(Readline.line_buffer)
    if argv.any? || (cmdline =~ /#{Regexp.escape(cmd)}\s/)
      complete_path(dirtree, cwd, argv.last.to_s, cmd == 'cd')
    else
      options(cmd.to_s, shell_commands)
    end
  end

  # TODO: file_only
  def complete_path(dirtree, cwd, path, dir_only)
    dir, file = File.dirname(path), File.basename(path)
    if path.end_with?('/')
      dir, file = File.dirname(File.join(path, 'abc')), ''
    end
    abs_dir = File.expand_path(dir, cwd)

    listing = dirtree.listing(abs_dir)

    results = listing.directories.select{|x| x.start_with?(file)}.map{|d| d + '/'}
    exactly_one_dir = results.length == 1
    unless dir_only
      results.concat listing.files.select{|x| x.start_with?(file)}
    end

    # hack to make no space if only one result and result is a dir
    results = [results.first, "#{results.first}..."] if results.count == 1 && exactly_one_dir

    # Don't change what you are typing to just the last part of the path
    prefix =
      if !path.include?('/')
        ''
      elsif dir == '/'
        '/'
      else
        "#{dir}/"
      end
    results.map! { |res| prefix + res }

    results
  end

  def shell_commands
    @shell_commands ||=
      Shell.instance_methods.select{|m| m.to_s.start_with?("cmd_")}.map{|m| m.to_s[4..-1]}
  end

  def options(cmd, opts)
    opts.select{|opt| opt.start_with?(cmd)}
  end
end

class Shell
  attr_reader :dirtree, :cwd

  def initialize
    @dirtree = DirTree.new
    @old_cwd = @cwd = '/'
    Readline.completion_proc = proc{ |input| TabCompletion.complete(dirtree, cwd, input) }
  end

  def stderr(msg, prefix=true)
    msg = "dropsh: #{msg}" if prefix
    STDERR.puts msg
    true
  end

  def readline
    prompt = "#{'dropbox'.red.bold}:#{cwd.blue.bold}$ "
    Readline.readline(prompt, true)
  rescue Interrupt
    puts
    ''
  end
    

  def run
    while cmdline = readline
      cmd, *argv = Shellwords.shellsplit(cmdline)
      if cmd == nil
        # noop
      elsif cmd == 'exit'
        stderr 'Use Ctrl-D to exit (safety first!)'
      elsif respond_to?(:"cmd_#{cmd}")
        send :"cmd_#{cmd}", argv
      else
        stderr "#{cmd}: command not found", false
      end
    end
    puts
  end

  def abspath(path)
    File.expand_path(path, cwd)
  end

  def cmd_cd(argv)
    stderr("cd: too many arguments") && return if argv.length > 1
    path = argv.first || '/'
    new_path = path == '-' ? @old_cwd : abspath(path)

    if !dirtree.exists?(new_path)
      stderr "cd: #{path}: No such file or directory"
    elsif !dirtree.is_dir?(new_path)
      stderr "cd: #{path}: Not a directory"
    else
      @old_cwd, @cwd = @cwd, new_path
    end
  end

  def cmd_ls(argv)
    # TODO: globs...
    stderr("ls: too many arguments") && return if argv.length > 1 # could support this when needed
    path = argv.length == 0 ? cwd : argv.first
    puts dirtree.listing(abspath(path))
  end

  def cmd_get(argv, silent: false)
    stderr("Usage: get <filename> [local_filename]") && return unless [1,2].include?(argv.length)
    src, dest = argv
    output = DropboxUploader.command_output(['download', abspath(src), dest].compact)
    puts output unless silent
  end

  def cmd_mv(argv, silent: false)
    stderr("Usage: mv <src> <dest>") && return unless argv.length == 2
    src, dest = argv
    output = DropboxUploader.command_output(['move', abspath(src), abspath(dest)])
    [src + '/..', dest, dest + '/..'].each do |dir|
      dirtree.clear_listing(abspath(dir))
    end
    puts output unless silent
  end


  #### "GET AND RUN" COMMANDS"

  # TODO: exec (parallel style, run any shell command on file)
  # exec eog {foo.jpg}
  # exec foo.jpg eog {}
  # exec eog {} ::: a.jpg b.jpg c.jpg

  def cmd_grep(argv)
    # TODO: multiple filenames / globs ...
    stderr("Usage: grep <regex> <filename>") && return unless argv.length == 2
    get_and_run(argv[1], 'grep', "grep #{Shellwords.shellescape argv.first}", silent: true)
  end

  def get_and_run(path, cmdname, cmd, silent: false)
    Tempfile.open("dropsh_#{cmdname}") do |f|
      cmd_get([path, f.path], silent: silent)
      cmd += " %s" unless cmd.include?("%s")
      system(cmd % f.path)
    end
  end

  GET_AND_RUN_COMMANDS = {
    exif: 'exif',
    eog: 'eog',
    cat: 'cat',
    less: 'less',
    exifdate: ["exif %s | grep Date.and.Time |head -1|cut -f2 -d'|' | sed -e s/:/-/ -e s/:/-/", {silent: true}]
  }

  GET_AND_RUN_COMMANDS.each do |cmdname, cmd|
    define_method(:"cmd_#{cmdname}") do |argv|
      cmd, opts = [cmd].flatten
      stderr("Usage: cmdname <filename>") && return if argv.length != 1
      get_and_run(argv.first, cmdname, cmd, **(opts || {}))
    end
  end
end

Shell.new.run
