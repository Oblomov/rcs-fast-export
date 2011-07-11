#!/usr/bin/ruby

=begin
TODO
	* Refactor commit coalescing
	* Add --strict-symbol-check to only coalesce commits if their symbol lists are equal
	* Add support for commitid for coalescing commits
	* Further coalescing options? (e.g. small logfile differences)
	* Proper branching support in multi-file export
	* Optimize memory usage by discarding unneeded text
=end

require 'pp'
require 'set'

class NoBranchSupport < NotImplementedError ; end

# Integer#odd? was introduced in Ruby 1.8.7, backport it to
# older versions
unless 2.respond_to? :odd?
	class Integer
		def odd?
			self % 2 == 1
		end
	end
end

def usage
	STDERR.puts <<EOM
#{$0} [options] file [file ...]

Fast-export the RCS history of one or more files. If a directory is specified,
all RCS-tracked files in the directory and its descendants are exported.

When importing single files, their pathname is discarded during import. When
importing directories, only the specified directory component is discarded.

When importing a single file, RCS commits are converted one by one. Otherwise,
some heuristics is used to determine how to coalesce commits touching different
files.

Currently, commits are coalesced if they share the exact same log and if their
date differs by no more than the user-specified fuzziness. Additionally, the
symbols in one of the commit must be a subset of the symbols in the other
commit, unless --no-symbol-check is specified or rcs.symbolCheck is set to
false in the git configuration.

Typical usage:
    git init && rcs-fast-export.rb . | git fast-import && git reset

Options:
	--help, -h, -?		display this help text
	--authors-file, -A	specify a file containing username = Full Name <email> mappings
	--rcs-commit-fuzz	fuzziness in RCS commits to be considered a single one when
				importing multiple files
				(in seconds, defaults to 300, i.e. 5 minutes)
	--[no-]symbol-check	[do not] check symbols when coalescing commits
	--[no-]tag-each-rev	[do not] create a lightweight tag for each RCS revision when
				importing a single file
	--[no-]log-filename	[do not] prepend the filename to the commit log when importing
				a single file
	--skip-branches		when exporting multiple files with a branched history, export
				the main branch only instead of aborting due to the lack of
				support for branched multi-file history export



Config options:
	rcs.authorsFile		for --authors-file
	rcs.tagEachRev		for --tag-each-rev
	rcs.logFilename		for --log-filename
	rcs.commitFuzz		for --rcs-commit-fuzz
	rcs.symbolCheck		for --rcs-symbol-check
	rcs.tagFuzz		for --rcs-tag-fuzz

EOM
end

def not_found(arg)
	STDERR.puts "Could not find #{arg}"
end

# returns a hash that maps usernames to author names & emails
def load_authors_file(fn)
	hash = {}
	begin
		File.open(File.expand_path(fn)) do |io|
			io.each_line do |line|
				uname, author = line.split('=', 2)
				uname.strip!
				author.strip!
				STDERR.puts "Username #{uname} redefined to #{author}" if hash.has_key? uname
				hash[uname] = author
			end
		end
	rescue
		not_found(fn)
	end
	return hash
end

class Time
	def Time.rcs(string)
		fields = string.split('.')
		raise ArgumentError, "wrong number of fields for RCS date #{string}" unless fields.length == 6
		Time.utc(*fields)
	end
end

module RCS
	# strip an optional final ;
	def RCS.clean(arg)
		arg.chomp(';')
	end

	# strip the first and last @, and de-double @@s
	def RCS.sanitize(arg)
		case arg
		when Array
			ret = arg.dup
			raise 'malformed first line' unless ret.first[0,1] == '@'
			raise 'malformed last line' unless ret.last[-1,1] == '@'
			ret.first.sub!(/^@/,'')
			ret.last.sub!(/@$/,'')
			ret.map { |l| l.gsub('@@','@') }
		when String
			arg.chomp('@').sub(/^@/,'').gsub('@@','@')
		else
			raise
		end
	end

	# clean and sanitize
	def RCS.at_clean(arg)
		RCS.sanitize RCS.clean(arg)
	end

	def RCS.mark(key)
		@@marks ||= {}
		if @@marks.key? key
			@@marks[key]
		else
			@@marks[key] = @@marks.length + 1
		end
	end

	def RCS.blob(file, rev)
		RCS.mark([file, rev])
	end

	def RCS.commit(commit)
		RCS.mark(commit)
	end

	class File
		attr_accessor :head, :comment, :desc, :revision, :fname, :mode
		def initialize(fname, executable)
			@fname = fname.dup
			@head = nil
			@comment = nil
			@desc = []
			@revision = Hash.new { |h, r| h[r] = Revision.new(self, r) }
			@mode = executable ? '755' : '644'
		end

		def has_revision?(rev)
			@revision.has_key?(rev) and not @revision[rev].author.nil?
		end

		def export_commits(opts={})
			counter = 0
			exported = []
			until @revision.empty?
				counter += 1

				# a string sort is a very good candidate for
				# export order, getting a miss only for
				# multi-digit revision components
				keys = @revision.keys.sort

				STDERR.puts "commit export loop ##{counter}"
				STDERR.puts "\t#{exported.length} commits exported so far: #{exported.join(', ')}" unless exported.empty?
				STDERR.puts "\t#{keys.size} to export: #{keys.join(', ')}"

				keys.each do |key|
					rev = @revision[key]
					# the parent commit is rev.next if we're on the
					# master branch (rev.branch is nil) or
					# rev.diff_base otherwise
					from = rev.branch.nil? ? rev.next : rev.diff_base
					# A commit can only be exported if it has no
					# parent, or if the parent has been exported
					# already. Skip this commit otherwise
					if from and not exported.include? from
						next
					end

					branch = rev.branch || 'master'
					author = opts[:authors][rev.author] || "#{rev.author} <empty>"
					date = "#{rev.date.tv_sec} +0000"
					log = String.new
					if opts[:log_filename]
						log << @fname << ": "
					end
					log << rev.log.join

					puts "commit refs/heads/#{branch}"
					puts "mark :#{RCS.commit key}"
					puts "committer #{author} #{date}"
					puts "data #{log.length}"
					puts log unless log.empty?
					puts "from :#{RCS.commit from}" if rev.branch_point
					puts "M #{@mode} :#{RCS.blob @fname, key} #{@fname}"

					# TODO FIXME this *should* be safe, in
					# that it should not unduly move
					# branches back in time, but I'm not
					# 100% sure ...
					rev.branches.each do |sym|
						puts "reset refs/heads/#{sym}"
						puts "from :#{RCS.commit key}"
					end
					rev.symbols.each do |sym|
						puts "reset refs/tags/#{sym}"
						puts "from :#{RCS.commit key}"
					end
					if opts[:tag_each_rev]
						puts "reset refs/tags/#{key}"
						puts "from :#{RCS.commit key}"
					end

					exported.push key
				end
				exported.each { |k| @revision.delete(k) }
			end
		end
	end

	class Revision
		attr_accessor :rev, :author, :state, :next
		attr_accessor :branches, :log, :text, :symbols
		attr_accessor :branch, :diff_base, :branch_point
		attr_reader   :date
		def initialize(file, rev)
			@file = file
			@rev = rev
			@author = nil
			@date = nil
			@state = nil
			@next = nil
			@branches = Set.new
			@branch = nil
			@branch_point = nil
			@diff_base = nil
			@log = []
			@text = []
			@symbols = Set.new
		end

		def date=(str)
			@date = Time.rcs(str)
		end

		def blob
			str = @text.join('')
			ret = "blob\nmark :#{RCS.blob @file.fname, @rev}\ndata #{str.length}\n#{str}\n"
			ret
		end
	end

	def RCS.parse(fname, rcsfile)
		rcs = RCS::File.new(fname, ::File.executable?(rcsfile))

		::File.open(rcsfile, 'r:ASCII-8BIT') do |file|
			status = [:basic]
			rev = nil
			lines = []
			difflines = []
			file.each_line do |line|
				case status.last
				when :basic
					command, args = line.split($;,2)
					next if command.empty?

					if command.chomp!(';')
						STDERR.puts "Skipping empty command #{command.inspect}" if $DEBUG
						next
					end

					case command
					when 'head'
						rcs.head = RCS.clean(args.chomp)
					when 'symbols'
						status.push :symbols
						next if args.empty?
						line = args; redo
					when 'comment'
						rcs.comment = RCS.at_clean(args.chomp)
					when /^[0-9.]+$/
						rev = command.dup
						if rcs.has_revision?(rev)
							status.push :revision_data
						else
							status.push :new_revision
						end
					when 'desc'
						status.push :desc
						lines.clear
						status.push :read_lines
					when 'branch', 'access', 'locks', 'expand'
						STDERR.puts "Skipping unhandled command #{command.inspect}" if $DEBUG
						status.push :skipping_lines
						next if args.empty?
						line = args; redo
					else
						raise "Unknown command #{command.inspect}"
					end
				when :skipping_lines
					status.pop if line.strip.chomp!(';')
				when :symbols
					# we can have multiple symbols per line
					pairs = line.strip.split($;)
					pairs.each do |pair|
						sym, rev = pair.strip.split(':',2);
						if rev
							status.pop if rev.chomp!(';')
							rcs.revision[rev].symbols << sym
						else
							status.pop
						end
					end
				when :desc
					rcs.desc.replace lines.dup
					status.pop
				when :read_lines
					# we sanitize lines as we read them

					actual_line = line.dup

					# the first line must begin with a @, which we strip
					if lines.empty?
						ats = line.match(/^@+/)
						raise 'malformed line' unless ats
						actual_line.replace line.sub(/^@/,'')
					end

					# if the line ends with an ODD number of @, it's the
					# last line -- we work on actual_line so that content
					# such as @\n or @ work correctly (they would be
					# encoded respectively as ['@@@\n','@\n'] and
					# ['@@@@\n']
					ats = actual_line.chomp.match(/@+$/)
					if nomore = (ats && Regexp.last_match(0).length.odd?)
						actual_line.replace actual_line.chomp.sub(/@$/,'')
					end
					lines << actual_line.gsub('@@','@')
					if nomore
						status.pop
						redo
					end
				when :new_revision
					case line.chomp
					when /^date\s+(\S+);\s+author\s+(\S+);\s+state\s+(\S+);$/
						rcs.revision[rev].date = $1
						rcs.revision[rev].author = $2
						rcs.revision[rev].state = $3
					when 'branches'
						status.push :branches
					when /branches\s*;/
						next
					when /^next\s+(\S+)?;$/
						nxt = rcs.revision[rev].next = $1
						next unless nxt
						raise "multiple diff_bases for #{nxt}" unless rcs.revision[nxt].diff_base.nil?
						rcs.revision[nxt].diff_base = rev
						rcs.revision[nxt].branch = rcs.revision[rev].branch
					else
						status.pop
					end
				when :branches
					candidate = line.split(';',2)
					branch = candidate.first.strip
					rcs.revision[rev].branches << branch
					raise "multiple diff_bases for #{branch}" unless rcs.revision[branch].diff_base.nil?
					rcs.revision[branch].diff_base = rev
					# we drop the last number from the branch name
					rcs.revision[branch].branch = branch.sub(/\.\d+$/,'.x')
					rcs.revision[branch].branch_point = rev
					status.pop if candidate.length > 1
				when :revision_data
					case line.chomp
					when 'log'
						status.push :log
						lines.clear
						status.push :read_lines
					when 'text'
						if rev == rcs.head
							status.push :head
						else
							status.push :diff
						end
						lines.clear
						status.push :read_lines
					else
						status.pop
					end
				when :log
					rcs.revision[rev].log.replace lines.dup
					status.pop
				when :head
					rcs.revision[rev].text.replace lines.dup
					puts rcs.revision[rev].blob
					status.pop
				when :diff
					difflines.replace lines.dup
					difflines.pop if difflines.last.empty?
					base = rcs.revision[rev].diff_base
					unless rcs.revision[base].text
						pp rcs
						puts rev, base
						raise 'no diff base!'
					end
					# deep copy
					buffer = []
					rcs.revision[base].text.each { |l| buffer << [l.dup] }

					adding = false
					index = nil
					count = nil

					while l = difflines.shift
						if adding
							raise 'negative index during insertion' if index < 0
							raise 'negative count during insertion' if count < 0
							adding << l
							count -= 1
							# collected all the lines, put the before
							unless count > 0
								unless buffer[index]
									buffer[index] = []
								end
								buffer[index].unshift(*adding)
								adding = false
							end
							next
						end

						l.chomp!
						raise 'malformed diff' unless l =~ /^([ad])(\d+) (\d+)$/
						diff_cmd = $1.intern
						index = $2.to_i
						count = $3.to_i
						case diff_cmd
						when :d
							# for deletion, index 1 is the first index, so the Ruby
							# index is one less than the diff one
							index -= 1
							# we replace them with empty string so that 'a' commands
							# referring to the same line work properly
							while count > 0
								buffer[index].clear
								index += 1
								count -= 1
							end
						when :a
							# addition will prepend the appropriate lines
							# to the given index, and in this case Ruby
							# and diff indices are the same
							adding = []
						end
					end

					# turn the buffer into an array of lines, deleting the empty ones
					buffer.delete_if { |l| l.empty? }
					buffer.flatten!

					rcs.revision[rev].text = buffer
					puts rcs.revision[rev].blob
					status.pop
				else
					raise "Unknown status #{status.last}"
				end
			end
		end

		# clean up the symbols/branches: look for revisions that have
		# one or more symbols but no dates, and make them into
		# branches, pointing to the highest commit with that key
		branches = []
		keys = rcs.revision.keys
		rcs.revision.each do |key, rev|
			if rev.date.nil? and not rev.symbols.empty?
				top = keys.select { |k| k.match(/^#{key}\./) }.sort.last
				tr = rcs.revision[top]
				raise "unhandled complex branch structure met: #{rev.inspect} refers #{tr.inspect}" if tr.date.nil?
				tr.branches |= rev.symbols
				branches << key
			end
		end
		branches.each { |k| rcs.revision.delete k }

		return rcs
	end

	class Tree
		def initialize(commit)
			@commit = commit
			@files = Hash.new
		end

		def merge!(tree)
			testfiles = @files.dup
			tree.each { |rcs, rev| self.add(rcs, rev, testfiles) }
			# the next line is only reached if all the adds were
			# successful, so the merge is atomic
			@files.replace testfiles
		end

		def add(rcs, rev, file_list=@files)
			if file_list.key? rcs
				prev = file_list[rcs]
				if prev.log == rev.log
					str = "re-adding existing file #{rcs.fname} (old: #{prev.rev}, new: #{rev.rev})"
				else
					str = "re-adding existing file #{rcs.fname} (old: #{[prev.rev, prev.log.to_s].inspect}, new: #{[rev.rev, rev.log.to_s].inspect})"
				end
				if prev.text != rev.text
					raise str
				else
					@commit.warn_about str
				end
			end
			file_list[rcs] = rev
		end

		def each &block
			@files.each &block
		end

		def to_a
			files = []
			@files.map do |rcs, rev|
				files << "M #{rcs.mode} :#{RCS.blob rcs.fname, rev.rev} #{rcs.fname}"
			end
			files
		end

		def filenames
			@files.map { |rcs, rev| rcs.fname }
		end

		def to_s
			self.to_a.join("\n")
		end
	end

	class Commit
		attr_accessor :date, :log, :symbols, :author, :branch
		attr_accessor :tree
		attr_accessor :min_date, :max_date
		def initialize(rcs, rev)
			raise NoBranchSupport if rev.branch
			self.date = rev.date.dup
			self.min_date = self.max_date = self.date
			self.log = rev.log.dup
			self.symbols = rev.symbols.dup
			self.author = rev.author
			self.branch = rev.branch

			self.tree = Tree.new self
			self.tree.add rcs, rev
		end

		def to_a
			[self.min_date, self.date, self.max_date, self.branch, self.symbols, self.author, self.log, self.tree.to_a]
		end

		def warn_about(str)
			warn str + " for commit on #{self.date}"
		end

		# Sort by date and then by number of symbols
		def <=>(other)
			ds = self.date <=> other.date
			if ds != 0
				return ds
			else
				return self.symbols.length <=> other.symbols.length
			end
		end

		def merge!(commit)
			self.tree.merge! commit.tree
			if commit.max_date > self.max_date
				self.max_date = commit.max_date
			end
			if commit.min_date < self.min_date
				self.min_date = commit.min_date
			end
			self.symbols.merge commit.symbols
		end

		def export(opts={})
			xbranch = self.branch || 'master'
			xauthor = opts[:authors][self.author] || "#{self.author} <empty>"
			xlog = self.log.to_s
			numdate = self.date.tv_sec
			xdate = "#{numdate} +0000"
			key = numdate.to_s

			puts "commit refs/heads/#{xbranch}"
			puts "mark :#{RCS.commit key}"
			puts "committer #{xauthor} #{xdate}"
			puts "data #{xlog.length}"
			puts xlog unless xlog.empty?
			# TODO branching support for multi-file export
			# puts "from :#{RCS.commit from}" if self.branch_point
			puts self.tree.to_s

			# TODO branching support for multi-file export
			# rev.branches.each do |sym|
			# 	puts "reset refs/heads/#{sym}"
			# 	puts "from :#{RCS.commit key}"
			# end

			self.symbols.each do |sym|
				puts "reset refs/tags/#{sym}"
				puts "from :#{RCS.commit key}"
			end

		end
	end
end

require 'getoptlong'

opts = GetoptLong.new(
	# Authors file, like git-svn and git-cvsimport, more than one can be
	# specified
	['--authors-file', '-A', GetoptLong::REQUIRED_ARGUMENT],
	# RCS file suffix, like RCS
	['--rcs-suffixes', '-x', GetoptLong::REQUIRED_ARGUMENT],
	# Date fuzziness for commits to be considered the same (in seconds)
	['--rcs-commit-fuzz', GetoptLong::REQUIRED_ARGUMENT],
	# check symbols when coalescing?
	['--symbol-check', GetoptLong::NO_ARGUMENT],
	['--no-symbol-check', GetoptLong::NO_ARGUMENT],
	# tag each revision?
	['--tag-each-rev', GetoptLong::NO_ARGUMENT],
	['--no-tag-each-rev', GetoptLong::NO_ARGUMENT],
	# prepend filenames to commit logs?
	['--log-filename', GetoptLong::NO_ARGUMENT],
	['--no-log-filename', GetoptLong::NO_ARGUMENT],
	# skip branches when exporting a whole tree?
	['--skip-branches', GetoptLong::NO_ARGUMENT],
	['--help', '-h', '-?', GetoptLong::NO_ARGUMENT]
)

# We read options in order, but they apply to all passed parameters.
# TODO maybe they should only apply to the following, unless there's only one
# file?
opts.ordering = GetoptLong::RETURN_IN_ORDER

file_list = []
parse_options = {
	:authors => Hash.new,
	:commit_fuzz => 300,
	:tag_fuzz => -1,
}

# Read config options
`git config --get-all rcs.authorsfile`.each_line do |fn|
	parse_options[:authors].merge! load_authors_file(fn.chomp)
end

parse_options[:tag_each_rev] = (
	`git config --bool rcs.tageachrev`.chomp == 'true'
) ? true : false

parse_options[:log_filename] = (
	`git config --bool rcs.logfilename`.chomp == 'true'
) ? true : false

fuzz = `git config --int rcs.commitFuzz`.chomp
parse_options[:commit_fuzz] = fuzz.to_i unless fuzz.empty?

fuzz = `git config --int rcs.tagFuzz`.chomp
parse_options[:tag_fuzz] = fuzz.to_i unless fuzz.empty?

parse_options[:symbol_check] = (
	`git config --bool rcs.symbolcheck`.chomp == 'false'
) ? false : true

opts.each do |opt, arg|
	case opt
	when '--authors-file'
		authors = load_authors_file(arg)
		redef = parse_options[:authors].keys & authors.keys
		STDERR.puts "Authors file #{arg} redefines #{redef.join(', ')}" unless redef.empty?
		parse_options[:authors].merge!(authors)
	when '--rcs-suffixes'
		# TODO
	when '--rcs-commit-fuzz'
		parse_options[:commit_fuzz] = arg.to_i
	when '--rcs-tag-fuzz'
		parse_options[:tag_fuzz] = arg.to_i
	when '--symbol-check'
		parse_options[:symbol_check] = true
	when '--no-symbol-check'
		parse_options[:symbol_check] = false
	when '--tag-each-rev'
		parse_options[:tag_each_rev] = true
	when '--no-tag-each-rev'
		# this is the default, which is fine since the missing key
		# (default) returns nil which is false in Ruby
		parse_options[:tag_each_rev] = false
	when '--log-filename'
		parse_options[:log_filename] = true
	when '--no-log-filename'
		# this is the default, which is fine since the missing key
		# (default) returns nil which is false in Ruby
		parse_options[:log_filename] = false
	when '--skip-branches'
		parse_options[:skip_branches] = true
	when ''
		file_list << arg
	when '--help'
		usage
		exit
	end
end

if parse_options[:tag_fuzz] < parse_options[:commit_fuzz]
	parse_options[:tag_fuzz] = parse_options[:commit_fuzz]
end

require 'etc'

user = Etc.getlogin || ENV['USER']

# steal username/email data from other init files that may contain the
# information
def steal_username
	[
		# the user's .hgrc file for a username field
		['~/.hgrc',   /^\s*username\s*=\s*(["'])?(.*)\1$/,       2],
		# the user's .(g)vimrc for a changelog_username setting
		['~/.vimrc',  /changelog_username\s*=\s*(["'])?(.*)\1$/, 2],
		['~/.gvimrc', /changelog_username\s*=\s*(["'])?(.*)\1$/, 2],
		[]
	].each do |fn, rx, idx|
		file = File.expand_path fn
		if File.readable?(file) and File.read(file) =~ rx
			parse_options[:authors][user] = Regexp.last_match(idx).strip
			break
		end
	end
end

if user and not user.empty? and not parse_options[:authors].has_key?(user)
	name = ENV['GIT_AUTHOR_NAME'] || ''
	name.replace(`git config user.name`.chomp) if name.empty?
	name.replace(Etc.getpwnam(user).gecos) if name.empty?

	if name.empty?
		# couldn't find a name, try to steal data from other sources
		steal_username
	else
		# if we found a name, try to find an email too
		email = ENV['GIT_AUTHOR_EMAIL'] || ''
		email.replace(`git config user.email`.chomp) if email.empty?

		if email.empty?
			# couldn't find an email, try to steal data too
			steal_username
		else
			# we got both a name and email, fill the info
			parse_options[:authors][user] = "#{name} <#{email}>"
		end
	end
end

if file_list.empty?
	usage
	exit 1
end

SFX = ',v'

status = 0

rcs = []
file_list.each do |arg|
	case ftype = File.ftype(arg)
	when 'file'
		if arg[-2,2] == SFX
			if File.exists? arg
				rcsfile = arg.dup
			else
				not_found "RCS file #{arg}"
				status |= 1
			end
			filename = File.basename(arg, SFX)
		else
			filename = File.basename(arg)
			path = File.dirname(arg)
			rcsfile = File.join(path, 'RCS', filename) + SFX
			unless File.exists? rcsfile
				rcsfile.replace File.join(path, filename) + SFX
				unless File.exists? rcsfile
					not_found "RCS file for #{filename} in #{path}"
				end
			end
		end
		rcs << RCS.parse(filename, rcsfile)
	when 'directory'
		pattern = File.join(arg, '**', '*' + SFX)
		Dir.glob(pattern).each do |rcsfile|
			filename = File.basename(rcsfile, SFX)
			path = File.dirname(rcsfile)
			path.sub!(/\/?RCS$/, '') # strip final /RCS if present
			path.sub!(/^#{Regexp.escape arg}\/?/, '') # strip initial dirname
			filename = File.join(path, filename) unless path.empty?
			begin
				rcs << RCS.parse(filename, rcsfile)
			rescue Exception => e
				STDERR.puts "Failed to parse #{filename} @ #{rcsfile}:#{$.}"
				raise e
			end
		end
	else
		STDERR.puts "Cannot handle #{arg} of #{ftype} type"
		status |= 1
	end
end

if rcs.length == 1
	rcs.first.export_commits(parse_options)
else
	STDERR.puts "Preparing commits"

	commits = []

	rcs.each do |r|
		r.revision.each do |k, rev|
			begin
				commits << RCS::Commit.new(r, rev)
			rescue NoBranchSupport
				if parse_options[:skip_branches]
					STDERR.puts "Skipping revision #{rev.rev} for #{r.fname} (branch)"
				else raise
				end
			end
		end
	end

	STDERR.puts "Sorting by date"

	commits.sort!

	if $DEBUG
		STDERR.puts "RAW commits (#{commits.length}):"
		commits.each do |c|
			PP.pp c.to_a, $stderr
		end
	else
		STDERR.puts "#{commits.length} single-file commits"
	end

	STDERR.puts "Coalescing [1] by date with fuzz #{parse_options[:commit_fuzz]}"

	thisindex = commits.size
	commits.reverse_each do |c|
		nextindex = thisindex
		thisindex -= 1

		cfiles = Set.new c.tree.filenames
		ofiles = Set.new

		mergeable = []

		# test for mergeable commits by looking at following commits
		while nextindex < commits.size
			k = commits[nextindex]
			nextindex += 1

			# commits are date-sorted, so we know we can quit early if we are too far
			# for coalescing to work
			break if k.min_date > c.max_date + parse_options[:commit_fuzz]

			skipthis = false

			kfiles = Set.new k.tree.filenames

			if c.log != k.log or c.author != k.author or c.branch != k.branch
				skipthis = true
			end

			unless c.symbols.subset?(k.symbols) or k.symbols.subset?(c.symbols)
				cflist = cfiles.to_a.join(', ')
				kflist = kfiles.to_a.join(', ')
				if parse_options[:symbol_check]
					STDERR.puts "Not coalescing #{c.log.inspect}\n\tfor (#{cflist})\n\tand (#{kflist})"
					STDERR.puts "\tbecause their symbols disagree:\n\t#{c.symbols.to_a.inspect} and #{k.symbols.to_a.inspect} disagree on #{(c.symbols ^ k.symbols).to_a.inspect}"
					STDERR.puts "\tretry with the --no-symbol-check option if you want to merge these commits anyway"
					skipthis = true
				elsif $DEBUG
					STDERR.puts "Coalescing #{c.log.inspect}\n\tfor (#{cflist})\n\tand (#{kflist})"
					STDERR.puts "\twith disagreeing symbols:\n\t#{c.symbols.to_a.inspect} and #{k.symbols.to_a.inspect} disagree on #{(c.symbols ^ k.symbols).to_a.inspect}"
				end
			end

			# keep track of filenames touched by commits we are not merging with,
			# since we don't want to merge with commits that touch them, to preserve
			# the monotonicity of history for each file
			# TODO we could forward-merge with them, unless some of our files were
			# touched too.
			if skipthis
				# if the candidate touches any file already in the commit,
				# we can stop looking forward
				break unless cfiles.intersection(kfiles).empty?
				ofiles |= kfiles
				next
			end

			# the candidate has the same log, author, branch and appropriate symbols
			# does it touch anything in ofiles?
			unless ofiles.intersection(kfiles).empty?
				if $DEBUG
					cflist = cfiles.to_a.join(', ')
					kflist = kfiles.to_a.join(', ')
					oflist = ofiles.to_a.join(', ')
					STDERR.puts "Not coalescing #{c.log.inspect}\n\tfor (#{cflist})\n\tand (#{kflist})"
					STDERR.puts "\tbecause the latter intersects #{oflist} in #{(ofiles & kfiles).to_a.inspect}"
				end
				next
			end

			mergeable << k
		end

		mergeable.each do |k|
			begin
				c.merge! k
			rescue RuntimeError => err
				fuzz = c.date - k.date
				STDERR.puts "Fuzzy commit coalescing failed: #{err}"
				STDERR.puts "\tretry with commit fuzz < #{fuzz} if you don't want to see this message"
				break
			end
			commits.delete k
		end
	end

	if $DEBUG
		STDERR.puts "[1] commits (#{commits.length}):"
		commits.each do |c|
			PP.pp c.to_a, $stderr
		end
	else
		STDERR.puts "#{commits.length} coalesced commits"
	end

	commits.each { |c| c.export(parse_options) }

end

exit status
