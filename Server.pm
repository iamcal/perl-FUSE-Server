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
$VERSION = '1.01';

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
  $s = FUSE::Server->new({
      Port=>35008,
      MaxClients=>5000,
      Quiet=>1,
  });

  $status = $s->start();
  print "Server started: $status";

  $s->addCallback('BROADCASTALL',\&msg_broadcast);

  $s->addCallback('client_start',\&msg_client_start);

  $s->defaultCallback(\&unknown_command);

  $SIG{INT} = $SIG{TERM} = $SIG{HUP} = sub{$s->die();};

  $s->run();

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

The C<FUSE::Server> module will create a TCP FUSE server and dispatch messages to registered event handlers.

The external interface to C<FUSE::Server> is:

=over 4

=item $s = FUSE::Server->new( [%options] );

The object constructor takes the following arguments:

=item $s->start;

This method starts the server listening on it's port and returns the IP which it is listening on.

=item $s->addCallback( $message, $coderef );

This method registers the referenced subroutine as a handler for the specified message. When the server receives that message from the client, it checks it's handler hash and dispatches the decoded message to the sub. The sub should handle the following arguments:

( $userid, $msg, $params )

$userid contains the internal connection id for the client session. You can use this id to associate logins with clients. The $msg parameter contains the message the client sent. This allows one routine to handle more than one message. Messages from clients are typically uppercase, with lowercase messages being reserved for internal server events, such as client connect/disconnect. The available internal messages are:

B<client_start>
This message is sent when a client first connects. It is typically used to issue a I<SECRET_KEY> message to the client.

B<client_stop>
This message is sent when a client disconnects.

=item $s->defaultCallback( $coderef );

For all messages without an assigned handler, the default handler (if set) is sent the message. If you'd like to handle all messages internally, then setup C<defaultCallback> without setting up any normal C<addCallback>'s.

=item $s->die;

This method shuts down the server gracefully. Since the C<run> method loops, the C<die> method is generally set up to run on signal.

=item $s->run;

This method invokes the server's internal message pump. This loop can only be broken by a signal.

=back

=head1 AUTHOR

Cal Henderson, <cal@iamcal.com>

=cut
