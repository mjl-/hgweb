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


Hgweb: module {
	modinit:	fn(): string;
	init:	fn(nil: ref Draw->Context, args: list of string);
};


dflag := 1;
Nchanges:	con 20;
Titlelen:	con 90;


Change: adt {
	repo:		string;
	rev, p1, p2:	int;
	nodeidman:	string;
	user, date:	string;
	when, whentz:	int;
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
	if(cgi == nil || template == nil)
		return sprint("loading cgi or template: %r");
	cgi->init();
	template->init();

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
		form.print("htmlstart", ("repo", "")::nil);
		form.print("introchanges", nil);

		form.print("tablechangestart", ("tabid", "lastrepochanges")::("tabtitle", "last repository changes")::("printrepo", "")::nil);
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
				("printrepo", ""),
			};
			form.print("rowchange", args);
		}
		form.print("tablechangeend", nil);
		form.print("htmlend", nil);

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

		# read last n changes for repo
		(lrev, err) := lastrev(repo);
		if(err != nil)
			badrepo(repo);

		# read manifest
		paths: list of string;
		(paths, err) = readmanifest(repo, string lrev);
		if(err != nil)
			badrepo(repo);

		mans: list of list of (string, string); # keys: name, section
		bfiles: list of list of (string, string); # keys: path
		mfiles: list of list of (string, string); # keys: path
		for(l := paths; l != nil; l = tl l) {
			p := hd l;
			if(suffix(".b", p))
				bfiles = list of {("path", p)}::bfiles;
			else if(suffix(".m", p) && str->prefix("module/", p))
				mfiles = list of {("path", p)}::mfiles;
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

		changes: list of ref Change;
		r := lrev-Nchanges;
		if(r < 0)
			r = 0;
		for(; r <= lrev; r++) {
			(c, cerr) := readchange(repo, string r);
			if(cerr != nil)
				bad(cerr);
			changes = c::changes;
		}

		if(isrss) {
			items: list of ref Rssgen->Item;
			for(; changes != nil; changes = tl changes)
				items = change2rssitem(hd changes)::items;
			title := sprint("changes for hg repo %q", repo);
			url := sprint("http://%s/%sr/%s.rss", env->getenv("SERVER_NAME"), env->getenv("SCRIPT_NAME"), repo);
			descr := sprint("last %d changes for the mercurial repository %#q", Nchanges, repo);
			xml := rssgen->rssgen(title, url, descr, items);
			sys->print("status: 200 OK\r\ncontent-type: text/xml; charset=utf-8\r\n\r\n%s", xml);
			return;
		}

		form.print("httpheaders", nil);
		form.print("htmlstart", ("repo", repo)::nil);
		form.printl("introrepo", ("repo", repo)::("lastrev", string lrev)::nil, ("manpages", mans)::("bfiles", bfiles)::("mfiles", mfiles)::nil);

		form.print("tablechangestart", ("tabid", "changes")::("tabtitle", "changes")::nil);

		for(; changes != nil; changes = tl changes) {
			c := hd changes;
			args := list of {
				("repo", c.repo),
				("rev", string c.rev),
				("p1", prevstr(c.p1)),
				("p2", prevstr(c.p2)),
				("who", userstr(c.user)),
				("when", whenstr(c.when)),
				("why", title(c.msg)),
			};
			form.print("rowchange", args);
		}
		form.print("tablechangeend", nil);
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

		cmd := sprint("diff -r /n/hg/%s/files/%s /n/hg/%s/files/%s", repo, arevstr, repo, brevstr);
		say(sprint("diff cmd, %q", cmd));
		
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
		cmd := sprint("man2html %q", p);
		form.print("httpheaders", nil);
		err := sh->system(nil, cmd);
		if(err != nil)
			warn(sprint("man2html: %q: %s", cmd, err));
		sys->print("</BODY></HTML>\n");

	} else if(path == "style") {
		form.print("style", nil);

	} else {
		badpath(path);
	}
}

validrepo(s: string): int
{
	return str->drop(s, "0-9a-zA-Z") == nil;
}

validrev(s: string): int
{
	return s == "last" || str->drop(s, "0-9") == nil;
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
		f = f[:Titlelen-4];
	if(rem != "" && rem != "\n")
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
timestrs := array[] of {"min", "hour", "day", "week", "month", "year"};

whenstr(t: int): string
{
	t = daytime->now()-t;
	say(sprint("whenstr, new t %d", t));

	if(t < Min)
		return "just now";

	n: int;
	i := 1;
	for(;;) {
		if(i == len timedivs || t < timedivs[i]) {
			n = t/timedivs[i-1];
			break;
		}
		i++;
	}
	s := timestrs[i-1];
	if(n != 1)
		s += "s";
	return string n+" "+s;
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

change2rssitem(c: ref Change): ref Rssgen->Item
{
	url := sprint("http://%s/hg/%s/log/%d", env->getenv("SERVER_NAME"), c.repo, c.rev);
	return ref Rssgen->Item(title(c.msg), url, c.msg, c.when, c.whentz, url, "hg"::nil);
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
