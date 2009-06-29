implement Hgweb;

include "sys.m";
	sys: Sys;
	sprint: import sys;
include "draw.m";
include "arg.m";
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "daytime.m";
	daytime: Daytime;
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
include "rssgen.m";
	rssgen: Rssgen;
include "textmangle.m";
	textmangle: Textmangle;
	Mark: import Textmangle;


Hgweb: module {
	modinit:	fn(): string;
	init:	fn(nil: ref Draw->Context, args: list of string);
};


dflag := 1;
Nchanges:	con 20;
Titlelen:	con 70;


Change: adt {
	repo:		string;
	rev, p1, p2:	int;
	nodeidman:	string;
	user, date:	string;
	when, whentz:	int;
	branch:		string;
	files:		list of string;
	msg:		string;
};


modinit(): string
{
	sys = load Sys Sys->PATH;
	bufio = load Bufio Bufio->PATH;
	daytime = load Daytime Daytime->PATH;
	env = load Env Env->PATH;
        str = load String String->PATH;
	sh = load Sh Sh->PATH;
	lists = load Lists Lists->PATH;
	rssgen = load Rssgen Rssgen->PATH;
        cgi = load Cgi Cgi->PATH;
        template = load Template Template->PATH;
	textmangle = load Textmangle Textmangle->PATH;
	if(cgi == nil || template == nil || textmangle == nil)
		return sprint("loading cgi, template or textmangle: %r");
	cgi->init();
	template->init();
	textmangle->init();

	return nil;
}

form: ref Form;

init(nil: ref Draw->Context, nil: list of string)
{
	if(sys == nil)
		modinit();

	form = ref Form("hgweb");

	path := env->getenv("PATH_INFO");
	path = cgi->decode(path);

	if(path == "") {
		# read changes for all repo's

		(cl, err) := readchanges();
		if(err != nil)
			return form.print("error", ("error", err)::nil);

		form.print("httpheaders", nil);
		form.print("htmlstart", ("repo", "index")::nil);
		form.print("introchanges", nil);

		form.print("tableoverviewstart", ("tabid", "lastrepochanges")::("tabtitle", "last repository changes")::nil);
		ca := l2a(cl);
		sort(ca, gechangetime);

		for(i := 0; i < len ca; i++) {
			c := ca[i];
			args := list of {
				("repo", c.repo),
				("rev", string c.rev),
				("p1", prevstr(c.p1)),
				("p2", prevstr(c.p2)),
				("who", userstr(c.user)),
				("when", whenstr(c.when)),
				("why", title(c.msg)),
			};
			if(c.branch != nil)
				args = ("branch", c.branch)::args;
			form.print("rowoverview", args);
		}
		form.print("tableend", nil);
		form.print("htmlend", nil);

	} else if(path == "changes.rss") {
		(cl, err) := readchanges();
		if(err != nil)
			bad(err);

		items: list of ref Rssgen->Item;
		for(; cl != nil; cl = tl cl)
			items = change2rssitem(hd cl, 1)::items;
		title := "last change for each hg repo";
		url := sprint("http://%s/%schanges.rss", env->getenv("SERVER_NAME"), env->getenv("SCRIPT_NAME"));
		descr := "last changes for each mercurial repository";
		xml := rssgen->rssgen(title, url, descr, items);
		sys->print("status: 200 OK\r\ncontent-type: text/xml; charset=utf-8\r\n\r\n%s", xml);

	} else if(str->prefix("r/", path)) {
		repo: string;
		isrss := 0;
		if(suffix(".rss", path)) {
			isrss = 1;
			repo = path[len "r/":len path-len ".rss"];
		} else
			repo = path[len "r/":];

		if(!validrepo(repo))
			badpath(path);

		# read last rev number for repo
		(lrev, err) := lastrev(repo);
		if(err != nil)
			badrepo(repo);

		# read manifest
		paths: list of string;
		(paths, err) = readmanifest(repo, string lrev);
		if(err != nil)
			badrepo(repo);

		mans: list of list of (string, string); # keys: name, section
		bfiles, mfiles, cfiles, hfiles, sfiles, pyfiles: list of list of (string, string); # keys: path
		for(l := paths; l != nil; l = tl l) {
			p := hd l;
			if(suffix(".b", p))
				bfiles = list of {("path", p)}::bfiles;
			else if(suffix(".m", p) && str->prefix("module/", p))
				mfiles = list of {("path", p)}::mfiles;
			else if(suffix(".h", p))
				hfiles = list of {("path", p)}::hfiles;
			else if(suffix(".c", p))
				cfiles = list of {("path", p)}::cfiles;
			else if(suffix(".s", p))
				sfiles = list of {("path", p)}::sfiles;
			else if(suffix(".py", p))
				pyfiles = list of {("path", p)}::pyfiles;
			else if(str->prefix("man/", p)) {
				p = p[len "man/":];
				(sec, name) := str->splitstrl(p, "/");
				if(name == nil || str->splitstrl(name[1:], "/").t1 != nil)
					continue;
				mans = list of {("name", name[1:]), ("section", sec)}::mans;
			}
		}
		mans = lists->reverse(mans);
		bfiles = lists->reverse(bfiles);
		mfiles = lists->reverse(mfiles);
		cfiles = lists->reverse(cfiles);
		hfiles = lists->reverse(hfiles);
		sfiles = lists->reverse(sfiles);
		pyfiles = lists->reverse(pyfiles);

		# read last n changes
		startrev := lrev-Nchanges;
		if(startrev < 0)
			startrev = 0;
		(changes, cerr) := readchangerange(repo, lrev, startrev);
		if(cerr != nil)
			bad(cerr);

		if(isrss) {
			items: list of ref Rssgen->Item;
			for(; changes != nil; changes = tl changes)
				items = change2rssitem(hd changes, 0)::items;
			title := sprint("changes for hg repo %q", repo);
			url := sprint("http://%s/%sr/%s.rss", env->getenv("SERVER_NAME"), env->getenv("SCRIPT_NAME"), repo);
			descr := sprint("last %d changes for the mercurial repository %#q", Nchanges, repo);
			xml := rssgen->rssgen(title, url, descr, items);
			sys->print("status: 200 OK\r\ncontent-type: text/xml; charset=utf-8\r\n\r\n%s", xml);
			return;
		}

		readmep := sprint("/n/hg/%q/files/last/README", repo);
		fd := sys->open(readmep, Sys->OREAD);
		txt: string;
		if(fd != nil) {
			(lines, rerr) := textmangle->read(fd);
			if(rerr != nil)
				bad(rerr);
			t := textmangle->parse(lines);
			mangleincrhead(t);
			txt = textmangle->tohtmlpre(t);
		}
		fd = nil;

		form.print("httpheaders", nil);
		form.print("htmlstart", ("repo", repo)::nil);

		introargs := ("repo", repo)::("lastrev", string lrev)::nil;
		if(txt != nil)
			introargs = ("readmetxt", txt)::introargs;
		introlargs := list of {
			("manpages", mans),
			("bfiles", bfiles),
			("mfiles", mfiles),
			("hfiles", hfiles),
			("cfiles", cfiles),
			("sfiles", sfiles),
			("pyfiles", pyfiles),
		};
		form.printl("introrepo", introargs, introlargs);

		tabargs := ("tabid", "changes")::("tabtitle", "changes")::("repo", repo)::nil;
		if((oldrev := lrev-len changes) >= 0)
			tabargs = ("oldrev", string oldrev)::tabargs;
		form.print("tablechangestart", tabargs);

		for(; changes != nil; changes = tl changes) {
			c := hd changes;
			args := list of {
				("repo", c.repo),
				("pagerev", string lrev),
				("rev", string c.rev),
				("p1", prevstr(c.p1)),
				("p2", prevstr(c.p2)),
				("who", userstr(c.user)),
				("when", whenstr(c.when)),
				("why", title(c.msg)),
			};
			if(c.branch != nil)
				args = ("branch", c.branch)::args;
			if(c.rev != 0) {
				args = 
				("reva", string (c.rev-1))::
				("revb", string c.rev)::
				args;
			} else {
				say(sprint("c.rev %d", c.rev));
			}
			form.print("rowchange", args);
		}
		form.print("tableend", nil);
		form.print("htmlend", nil);

	} else if(str->prefix("diff/", path) && suffix(".diff", path)) {
		# path should look like: diff/$repo-$v1-$v2.diff
		dpath := path[len "diff/":len path-len ".diff"];

		(repo, diffstr) := str->splitstrl(dpath, "-");
		if(diffstr == nil || !validrepo(repo))
			badpath(path);
		diffstr = diffstr[1:];

		(arevstr, brevstr) := str->splitstrl(diffstr, "-");
		if(brevstr == nil || !validrev(arevstr) || !validrev(brevstr[1:]))
			badpath(path);
		brevstr = brevstr[1:];

		cmd := sprint("ndiff -rn /n/hg/%s/files/%s /n/hg/%s/files/%s", repo, arevstr, repo, brevstr);
		
		sys->print("status: 200 OK\r\ncontent-type: text/plain; charset=utf-8\r\n\r\n");
		err := sh->system(nil, cmd);
		if(err != nil)
			warn(sprint("%q: %s", cmd, err));

	} else if(str->prefix("man/", path) && suffix(".html", path)) {
		# path should look like: man/$repo/$rev/man/$section/$name.html
		mpath := path[len "man/":len path-len ".html"];

		(repo, rem) := str->splitstrl(mpath, "/");
		if(rem == nil || !validrepo(repo))
			badpath(path);
		rem = rem[1:];
		(rev, man) := str->splitstrl(rem, "/");
		if(man == nil || !validrev(rev) || !validmanpath(man[1:]))
			badpath(path);
		man = man[1:];

		p := sprint("/n/hg/%s/files/%s/%s", repo, rev, man);
		(ok, nil) := sys->stat(p);
		if(ok != 0)
			badpath(path);
		cmd := sprint("man2html %q | sed 's,\\[<a href=\"\\.\\./index\\.html\">manual index</a>\\]\\[<a href=\"INDEX\\.html\">section index</a>\\]<p><DL>,,' | sed 's!<A href=\"\\.\\./[0-9][0-9]*/[a-zA-Z0-9-_]*\\.html\"><I>(.*)</I>\\(([0-9][0-9]*)\\)</A>!\\1\\(\\2\\)!'", p);
		form.print("httpheaders", nil);
		err := sh->system(nil, cmd);
		if(err != nil && err != "some")
			warn(sprint("man2html: %q: %s", cmd, err));
		sys->print("</BODY></HTML>\n");

	} else if((isshort := str->prefix("log/short/", path)) || str->prefix("log/full/", path)) {
		# path should look like: log/(short full)/$repo/$rev
		lpath: string;
		if(isshort)
			lpath = path[len "log/short/":];
		else
			lpath = path[len "log/full/":];

		(repo, revstr) := str->splitstrl(lpath, "/");
		if(!validrepo(repo) || revstr == nil || !validrev(revstr[1:]))
			return badpath(path);
		revstr = revstr[1:];

		(rev, err) := findrev(repo, revstr);
		if(err != nil)
			bad(err);
		
		startrev := rev-Nchanges;
		if(startrev < 0)
			startrev = 0;
		(changes, cerr) := readchangerange(repo, rev, startrev);
		if(cerr != nil)
			bad(cerr);

		(lrev, lerr) := lastrev(repo);
		if(lerr != nil)
			bad(lerr);

		m20 := string max(rev-20, 0);
		m100 := string max(rev-100, 0);
		p20 := string min(rev+20, lrev);
		p100 := string min(rev+100, lrev);

		form.print("httpheaders", nil);
		form.print("htmlstart", ("repo", repo)::nil);

		revs: list of list of (string, string);
		for(l := changes; l != nil; l = tl l)
			revs = (("rev", string (hd l).rev)::nil)::revs;
		revs = lists->reverse(revs);
		form.printl("introlog", ("repo", repo)::nil, ("revs", revs)::nil);

		tabargs := list of {
			("m20",	m20),
			("m100",	m100),
			("p20",	p20),
			("p100",	p100),
			("rev",	revstr),
			("tabid", "log"),
			("tabtitle", "log"),
			("repo", repo),
		};
		if((oldrev := rev-len changes) >= 0)
			tabargs = ("oldrev", string oldrev)::tabargs;

		entry := "tablefullchange";
		if(isshort) {
			form.print("tablelogstart", tabargs);
			entry = "rowshortlog";
		} else
			form.print("linksfulllog", tabargs);

		for(; changes != nil; changes = tl changes) {
			c := hd changes;
			args := list of {
				("repo", c.repo),
				("pagerev", revstr),
				("rev", string c.rev),
				("p1", prevstr(c.p1)),
				("p2", prevstr(c.p2)),
				("nodeidman", c.nodeidman),
				("who", userstr(c.user)),
				("user", c.user),
				("when", whenstr(c.when)),
				("date", c.date),
				("why", title(c.msg)),
				("msg", c.msg),
			};
			if(c.branch != nil)
				args = ("branch", c.branch)::args;
			if(c.rev != 0) {
				args = 
				("reva", string (c.rev-1))::
				("revb", string c.rev)::
				args;
			}
			files: list of list of (string, string);
			for(f := c.files; f != nil; f = tl f)
				files = (("file", hd f)::nil)::files;
			files = lists->reverse(files);
			form.printl(entry, args, ("files", files)::nil);
		}

		if(isshort)
			form.print("tableend", nil);
		else
			form.print("linksfulllog", tabargs);
		form.print("htmlend", nil);

	} else if(path == "style") {
		form.print("style", nil);

	} else {
		badpath(path);
	}
}

min(a, b: int): int
{
	if(a < b)
		return a;
	return b;
}

max(a, b: int): int
{
	if(a > b)
		return a;
	return b;
}

validrepo(s: string): int
{
	return s != nil && str->drop(s, "0-9a-zA-Z") == nil;
}

validrev(s: string): int
{
	return s == "last" || s != nil && str->drop(s, "0-9") == nil;
}

validmanpath(s: string): int
{
	man, sec, name: string;
	(man, s) = str->splitstrl(s, "/");
	if(s != nil) (sec, s) = str->splitstrl(s[1:], "/");
	if(s != nil) (name, s) = str->splitstrl(s[1:], "/");
	return s == nil && sec != nil && name != nil && !substr("..", sec) && !substr("/", sec) && !substr("..", name) && !substr("/", name);
}

substr(sub, s: string): int
{
	return str->splitstrl(s, sub).t1 != nil;
}

findrev(repo, revstr: string): (int, string)
{
	if(revstr == "last")
		return lastrev(repo);

	(rev, rem) := str->toint(revstr, 10);
	if(rem != nil)
		return (0, sprint("bad revision number: %q", rem));
	return (rev, nil);
}

prevstr(p: int): string
{
	if(p == -1)
		return "";
	return string p;
}

userstr(s: string): string
{
	return str->splitl(s, "<").t0;
}

title(s: string): string
{
	(f, rem) := str->splitstrl(s, "\n");
	if(len f > Titlelen)
		f = f[:Titlelen-4]+"...";
	else if(rem != nil && rem != "\n")
		f += " ...";
	return f;
}

sort[T](a: array of T, ge: ref fn(a, b: T): int)
{
	for(i := 1; i < len a; i++) {
		tmp := a[i];
		for(j := i; j > 0 && ge(a[j-1], tmp); j--)
			a[j] = a[j-1];
		a[j] = tmp;
	}
}

gechangetime(c1, c2: ref Change): int
{
	return c1.when+c1.whentz < c2.when+c2.whentz;
}


Min: con 60;
Hour: con 60*Min;
Day: con 24*Hour;
Week: con 7*Day;
Month: con 30*Day;
Year: con 365*Day;

timedivs := array[] of {Min, Hour, Day, Week, Month, Year};
timestrs := array[] of {"mins", "hours", "days", "weeks", "months", "years"};

whenstr(t: int): string
{
	t = daytime->now()-t;

	if(t < 2*Min)
		return "just now";

	i := 1;
	for(;;)
		if(i == len timedivs || t < 2*timedivs[i])
			return string (t/timedivs[i-1])+" "+timestrs[i-1];
		else
			i++;
}

lastrev(repo: string): (int, string)
{
	path := sprint("/n/hg/%s/lastrev", repo);
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
	s = s[:len s-1];
	keystr := key+": ";
	if(!str->prefix(keystr, s))
		return (nil, sprint("expected key %q, saw line %q", key, s));
	return (s[len keystr:], nil);
}

change2rssitem(c: ref Change, repotitle: int): ref Rssgen->Item
{
	url := sprint("http://%s/hg/%s/log/%d", env->getenv("SERVER_NAME"), c.repo, c.rev);
	t := string c.rev+": "+title(c.msg);
	if(repotitle)
		t = c.repo+" "+t;
	return ref Rssgen->Item(t, url, c.msg, c.when, c.whentz, url, "hg"::nil);
}

readmanifest(repo: string, revstr: string): (list of string, string)
{
	p := sprint("/n/hg/%s/manifest/%s", repo, revstr);
	b := bufio->open(p, Bufio->OREAD);
	if(b == nil)
		return (nil, sprint("open: %r"));
	l: list of string;
	for(;;) {
		s := b.gets('\n');
		if(s == nil)
			break;
		if(s[len s-1] == '\n')
			s = s[:len s-1];
		l = s::l;
	}
	return (lists->reverse(l), nil);
}

readchangerange(repo: string, last, first: int): (list of ref Change, string)
{
	l: list of ref Change;
	for(r := first; r <= last; r++) {
		(c, err) := readchange(repo, string r);
		if(err != nil)
			return (nil, err);
		l = c::l;
	}
	return (l, nil);
}

readchanges(): (list of ref Change, string)
{
	p := sprint("/n/hg");
	fd := sys->open(p, Sys->OREAD);
	if(fd == nil)
		return (nil, sprint("open: %r"));
	l: list of ref Change;
	for(;;) {
		(n, dirs) := sys->dirread(fd);
		if(n < 0)
			return (nil, sprint("dirread: %r"));
		if(n == 0)
			break;
		for(i := 0; i < len dirs && i < n; i++) {
			d := dirs[i];
			(c, err) := readchange(d.name, "last");
			if(err != nil)
				return (nil, err);
			l = c::l;
		}
	}
	l = lists->reverse(l);
	return (l, nil);
}

zerochange: Change;

readchange(repo: string, revstr: string): (ref Change, string)
{
	path := sprint("/n/hg/%s/log/%s", repo, revstr);
	b := bufio->open(path, Bufio->OREAD);
	if(b == nil)
		return (nil, sprint("bufio open: %r"));

	c := ref zerochange;
	c.repo = repo;

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
	if(revstr != "last" && rr != int revstr)
		return (nil, sprint("change file claims revision %d, expected revisions %q", rr, revstr));
	if(rrs != nil)
		return (nil, sprint("bad revision: %q", rev));
	c.rev = rr;

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

	(datestr, whenstr) := str->splitstrl(date, "; ");
	if(whenstr == nil)
		return (nil, sprint("malformed date, missing timestamp: %q", date));
	whenstr = whenstr[2:];

	whentzstr: string;
	(whenstr, whentzstr) = str->splitstrl(whenstr, " ");
	if(whentzstr == nil)
		return (nil, sprint("malformed date, missing timezone in timestamp: %q", date));
	whentzstr = whentzstr[1:];
	c.date = datestr;
	(c.when, err) = str->toint(whenstr, 10);
	if(err == nil) (c.whentz, err) = str->toint(whentzstr, 10);
	if(err != nil)
		return (nil, sprint("malformed timestamps, %q", date));

	s := b.gets('\n');
	if(str->prefix("branch: ", s)) {
		if(s[len s-1] == '\n')
			s = s[:len s-1];
		c.branch = s[len "branch: ":];
		s = b.gets('\n');
	}

	if(s != "files changed:\n")
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

mangleincrhead(mm: ref Mark)
{
	pick m := mm {
	Seq or List =>
		for(l := m.l; l != nil; l = tl l)
			mangleincrhead(hd l);
	Descr =>
		for(l := m.l; l != nil; l = tl l)
			mangleincrhead((hd l).s);
	Head =>
		m.level++;
	* =>	; # nothing
	};
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

l2a[T](l: list of T): array of T
{
	a := array[len l] of T;
	i := 0;
	for(; l != nil; l = tl l)
		a[i++] = hd l;
	return a;
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
