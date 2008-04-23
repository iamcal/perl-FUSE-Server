package FUSE::Server;

use strict;
use vars qw($VERSION @ISA @EXPORT @EXPORT_OK);

use IO::Socket;
use IO::Select;
use POSIX;

require Exporter;
require AutoLoader;

@ISA = qw(Exporter AutoLoader);
@EXPORT = qw();
$VERSION = '1.00';

my $nextid = 0;

###################################################################

sub new {
	my ($class,$params) = @_;
	my $self = {};
	bless $self,ref $class || $class;
	$self->{quiet} = ${$params}{Quiet};
	$self->{port} = ${$params}{Port} || 1024;
	$self->{maxc} = ${$params}{MaxClients} || SOMAXCONN;
	$self->{users} = {};
	return $self;
}

sub start{
	my ($self) = @_;

	$self->{die_now} = 0;

	$self->{main_sock} = IO::Socket::INET->new(LocalPort => $self->{port}, Type => SOCK_STREAM, Reuse => 1, Listen => $self->{maxc}) or die "Couldn't set up listening socket: $@\n";
	fcntl($self->{main_sock},F_SETFL(),O_NONBLOCK());

	$self->{readable_handles} = new IO::Select();
	$self->{readable_handles}->add($self->{main_sock});

	return "x.x.x.x";
}

sub stop{
	my ($self) = @_;
	$self->_stop();
}

sub addCallback{
	my ($self,$msg,$coderef) = @_;
	$self->{callbacks}{$msg} = $coderef;
}

sub defaultCallback{
	my ($self,$coderef) = @_;
	$self->{def_callback} = $coderef;
}

sub die{
	my ($self) = @_;
	$self->{die_now} = 1;
}

sub run{
	my ($self) = @_;
	until($self->{die_now}){
		my ($new_readable) = IO::Select->select($self->{readable_handles},undef,undef,undef);
		for my $sock(@$new_readable){
			if ($sock == $self->{main_sock}){
				my $new_sock = $sock->accept();
				fcntl($new_sock,F_SETFL(),O_NONBLOCK());
				$self->{readable_handles}->add($new_sock);
				$self->_newsession($new_sock);
			}else{
				my $buffer = <$sock>;
				if ($buffer){
					$self->_incoming($sock,$buffer);
				}else{
					$self->{readable_handles}->remove($sock);
					$self->_sessionclosed($sock);
					close($sock);
				}
			}
		}
	}
	$self->_stop();
}

sub send{
	my ($self,$uid,$msg,$params) = @_;
	my $sock;
	for (keys %{$self->{users}}){
		if ($self->{users}{$_}{id}==$uid){
			$sock = $self->{users}{$_}{sock};
			print $sock "# $msg\cM";
			print $sock "$params\cM";
			print $sock "##\cM\cJ";
			last;
		}
	}
}

sub sendAll{
	my ($self,$msg,$params) = @_;
	for (keys %{$self->{users}}){
		$self->send($self->{users}{$_}{id},$msg,$params);
	}
}

###################################################################

sub _stop{
	my ($self) = @_;
	close($self->{main_sock});
}

sub _newsession{
	my ($self,$sock) = @_;
	$nextid++;
	$self->{users}{$sock}{sock} = $sock;
	$self->{users}{$sock}{id} = $nextid;
	$self->{users}{$sock}{buffer} = '';
	print "New Connection: c$nextid...\n" unless ($self->{quiet});
	$self->_packet($sock,'client_start','');
}

sub _sessionclosed{
	my ($self,$sock) = @_;
	my $id = $self->{users}{$sock}{id};
	print "Connection Closed: c$id...\n" unless ($self->{quiet});
	$self->_packet($sock,'client_stop','');
	delete $self->{users}{$sock}; #do this AFTER we've called _packet else we redefine $sock as a key
}

sub _incoming{
	my ($self,$sock,$data) = @_;
	my $id = $self->{users}{$sock}{id};
	$self->{users}{$sock}{buffer} .= $data;
	my $ok = 1;
	my $buffer = $self->{users}{$sock}{buffer};
	while ($ok){
		$ok = 0;
		if (length($buffer) > 4){
			my $size = substr($buffer,0,4);
			if (length($buffer) >= 4+$size){
				my $packet = substr($buffer,4,$size);
				my $a = index($packet,' ');
				my $msg = substr($packet,0,$a);
				my $param = substr($packet,$a+1);
				$self->_packet($sock,$msg,$param);
				$buffer = substr($buffer,4+$size);
				$ok=1;
			}
		}
	}
	$self->{users}{$sock}{buffer} = $buffer;
}

sub _packet{
	my ($self,$sock,$msg,$params) = @_;
	my $id = $self->{users}{$sock}{id};
	print "Message: $msg (c$id)...\n" unless ($self->{quiet});

	if ($self->{callbacks}{$msg}){
		&{$self->{callbacks}{$msg}}($id,$msg,$params);
	}else{
		if ($self->{def_callback}){
			&{$self->{def_callback}}($id,$msg,$params);
		}
	}
}

###################################################################

1;
__END__

=head1 NAME

FUSE::Server - Perl-FUSE server

=head1 SYNOPSIS

  use FUSE::Server;
  $server = FUSE::Server->new({
      Port=>35008,
      MaxClients=>5000,
      Quiet=>1,
  });

  $status = $server->start();
  print "Server started: $status";

  $server->addCallback('BROADCASTALL',\&msg_broadcast);

  $server->addCallback('client_start',\&msg_client_start);

  $server->defaultCallback(\&unknown_command);

  $SIG{INT} = $SIG{TERM} = $SIG{HUP} = sub{$server->die();};

  sub msg_broadcast{
      my ($userid,$msg,$params) = @_;
      my @a = split /\//,$params;
      $server->sendAll($a[1],$a[2]);
  }

  sub msg_client_start{
      my ($userid,$msg,$params) = @_;
      $server->send($sock,'SECRET_KEY','123 456 789');
  }

  sub unknown_command{
      my ($userid,$msg,$params) = @_;
      print "Unknown command $msg\n";
  }


=head1 DESCRIPTION

Lorem ipsum dolor sit amet, consectetuer adipiscing elit, sed diam nonummy
nibh euismod tincidunt ut laoreet dolore magna aliquam erat volutpat. Ut
wisi enim ad minim veniam, quis nostrud exerci tation ullamcorper suscipit
lobortis nisl ut aliquip ex ea ccommodo consequat. Duis autem vel eum iriure
dolor in hendrerit in vulputate velit esse molestie consequat, vel illum
dolore eu feugiat nulla facilisis at vero eros et accumsan et iusto odio
dignissim qui blandit praesent luptatum zzril delenit augue duis

=head1 AUTHOR

Cal Henderson, cal@iamcal.com

=cut
