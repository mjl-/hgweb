implement Hgweb;

include "sys.m";
	sys: Sys;
	sprint: import sys;
include "draw.m";
include "arg.m";
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "env.m";
	env: Env;
include "string.m";
	str: String;
include "sh.m";
	sh: Sh;
include "lists.m";
	lists: Lists;
include "cgi.m";
	cgi: Cgi;
include "template.m";
	template: Template;
	Form: import template;


Hgweb: module {
	init:	fn(nil: ref Draw->Context, args: list of string);
};


dflag: int;
Nchanges:	con 5;


Change: adt {
	rev, p1, p2:	int;
	nodeidman:	string;
	user, date:	string;
	files:		list of string;
	msg:		string;
};


modinit(): string
{
	sys = load Sys Sys->PATH;
	bufio = load Bufio Bufio->PATH;
	env = load Env Env->PATH;
        str = load String String->PATH;
	sh = load Sh Sh->PATH;
	lists = load Lists Lists->PATH;
        cgi = load Cgi Cgi->PATH;
        template = load Template Template->PATH;
	if(cgi == nil || template == nil)
		return sprint("loading cgi or template: %r");
	cgi->init();
	template->init();

	return nil;
}

init(nil: ref Draw->Context, nil: list of string)
{
	if(sys == nil)
		modinit();

	form := ref Form("hgweb");

	path := env->getenv("PATH_INFO");
	path = cgi->decode(path);

	if(path == "changes") {
		# read changes for all repo's

		error("500", "not yet implemented");
		fail("not yet implemented");

	} else if(str->prefix("changes/", path)) {
		cpath := path[len "changes/":];
		if(str->splitstrl(cpath, "/").t1 != nil)
			badpath(path);

		repo: string;
		isrss := 0;
		if(suffix(".rss", cpath)) {
			isrss = 1;
			repo = cpath[:len cpath-len ".rss"];
		} else
			repo = cpath;

		# read last n changes for repo
		(lrev, err) := lastrev(repo);
		if(err != nil)
			badrepo(repo);

		changes: list of ref Change;
		r := lrev-Nchanges;
		if(r < 0)
			r = 0;
		for(; r <= lrev; r++) {
			(c, cerr) := readchange(repo, r);
			if(cerr != nil)
				bad(cerr);
			changes = c::changes;
		}

		# xxx print change
		if(isrss) {
			error("500", "not yet implemented");
			fail("changes/repo.rss not yet implemented");
		}

		sys->print("status: 200 OK\r\ncontent-type: text/plain; charset=utf-8\r\n\r\n");
		sys->print("%4s %4s %4s %15s %15s\n", "rev", "p1", "p2", "user", "date");
		for(l := changes; l != nil; l = tl l) {
			c := hd l;
			sys->print("%4d %4d %4d %15s %15s\n", c.rev, c.p1, c.p2, c.user, c.date);
		}

	} else if(str->prefix("diff/", path)) {
		dpath := path[len "diff/":];
		(repo, diffstr) := str->splitstrl(dpath, "/");
		if(diffstr == nil)
			badpath(path);

		if(str->drop(repo, "a-zA-Z0-9") != nil)
			badrepo(repo);

		if(!suffix(".diff", diffstr))
			badpath(path);
		revs := diffstr[:len diffstr-len ".diff"];
		(arevstr, brevstr) := str->splitstrl(revs, "-");
		if(brevstr == nil)
			badpath(path);
		brevstr = brevstr[1:];

		(arev, rema) := str->toint(arevstr, 10);
		(brev, remb) := str->toint(brevstr, 10);
		if(rema != nil || remb != nil)
			badpath(path);

		cmd := sprint("diff -r /n/hg/%s/files/%d /n/hg/%s/files/%d", repo, arev, repo, brev);
		
		sys->print("status: 200 OK\r\ncontent-type: text/plain; charset=utf-8\r\n\r\n");
		err := sh->system(nil, cmd);
		if(err != nil)
			warn(sprint("%q: %s", cmd, err));
	} else {
		badpath(path);
	}
}

lastrev(repo: string): (int, string)
{
	path := sprint("%s/lastrev", repo);
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return (-1, sprint("open: %r"));

	buf := array[32] of byte;
	n := sys->readn(fd, buf, len buf);
	if(n == 0)
		return (-1, "short read");
	if(n < 0)
		return (-1, sprint("read: %r"));
	s := string buf[:n];
	(lrev, rem) := str->toint(s, 10);
	if(rem != nil)
		return (-1, "bad revision in lastrev file");
	return (lrev, nil);
}

breadkey(b: ref Iobuf, key: string): (string, string)
{
	s := b.gets('\n');
	if(s == nil || s[len s-1] != '\n')
		return (nil, sprint("eof reading key %q", key));
	keystr := key+": ";
	if(!str->prefix(keystr, s))
		return (nil, sprint("expected key %q, saw line %q", key, s));
	return (s[len keystr:], nil);
}

zerochange: Change;

readchange(repo: string, r: int): (ref Change, string)
{
	path := sprint("/n/hg/%s/log/%d", repo, r);
	b := bufio->open(path, Bufio->OREAD);
	if(b == nil)
		return (nil, sprint("bufio open: %r"));

	c := ref zerochange;

	err: string;
	rev, parents, nodeidman, user, date: string;
	if(err == nil) (rev, err) = breadkey(b, "revision");
	if(err == nil) (parents, err) = breadkey(b, "parents");
	if(err == nil) (nodeidman, err) = breadkey(b, "manifest nodeid");
	if(err == nil) (user, err) = breadkey(b, "committer");
	if(err == nil) (date, err) = breadkey(b, "date");
	if(err != nil)
		return (nil, err);

	(rr, rrs) := str->toint(rev, 10);
	if(rr != r)
		return (nil, sprint("change file claims revision %d, expected revisions %d", rr, r));
	if(rrs != nil)
		return (nil, sprint("bad revision: %q", rev));
	c.rev = r;

	c.p1 = c.p2 = -1;
	if(parents == "none")
		;
	else if(str->splitstrl(parents, ", ").t1 == nil) {
		# single parent
		(p1, rem) := str->toint(parents, 10);
		if(rem != nil)
			return (nil, sprint("bad parent: %q", parents));
		c.p1 = p1;
	} else {
		# two parents
		(p1str, p2str) := str->splitstrl(parents, ", ");
		p2str = p2str[2:];

		(p1, p1rem) := str->toint(p1str, 10);
		(p2, p2rem) := str->toint(p2str, 10);
		if(p1rem != nil || p2rem != nil)
			return (nil, sprint("bad parents: %q", parents));
		c.p1 = p1;
		c.p2 = p2;
	}

	c.nodeidman = nodeidman;
	c.user = user;
	c.date = date;

	s := b.gets('\n');
	if(s != "files changes:\n")
		return (nil, sprint("expected list of changed files, saw %q", s));

	paths: list of string;
	for(;;) {
		l := b.gets('\n');
		if(l == nil || l[len l-1] != '\n')
			return (nil, "early eof while reading paths");
		l = l[:len l-1];
		if(l == nil)
			break;
		paths = l::paths;
	}
	paths = lists->reverse(paths);
	c.files = paths;

	msg := array[0] of byte;
	buf := array[Sys->ATOMICIO] of byte;
	for(;;) {
		n := b.read(buf, len buf);
		if(n == 0)
			break;
		if(n < 0)
			return (nil, sprint("reading commit message: %r"));
		nmsg := array[len msg+n] of byte;
		nmsg[:] = msg;
		nmsg[len msg:] = buf[:n];
		msg = nmsg;
	}
	c.msg = string msg;
	return (c, nil);
}

badpath(path: string)
{
	error("404", "Object Not Found");
	fail(sprint("no such path: %q", path));
}

badrepo(repo: string)
{
	error("404", "Repository Not Found");
	fail(sprint("no such repository: %q", repo));
}

bad(err: string)
{
	error("500", "Internal Error");
	fail(err);
}

error(status, msg: string)
{
	sys->print("status: %s %s\r\ncontent-type: text/html; charset=utf-8\r\n\r\n<html><head>\n<style type=\"text/css\">\nh1 { font-size: 1.4em; }\n</style>\n<title>%s - %s</title>\n</head><body>\n\n<h1>%s - %s</h1>\n</body></html>", status, msg, status, msg, status, msg);
}

suffix(suf, s: string): int
{
	return len suf <= len s && s[len s-len suf:] == suf;
}

warn(s: string)
{
	sys->fprint(sys->fildes(2), "%s\n", s);
}

say(s: string)
{
	if(dflag)
		warn(s);
}

fail(s: string)
{
	warn(s);
	raise "fail:"+s;
}
