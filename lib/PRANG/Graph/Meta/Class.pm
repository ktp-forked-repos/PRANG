package PRANG::Graph::Meta::Class;

use 5.010;
use Moose::Role;
use MooseX::Method::Signatures;
use Moose::Util::TypeConstraints;
use XML::LibXML;

has 'xml_attr' =>
	isa => "HashRef[HashRef[PRANG::Graph::Meta::Attr]]",
	is => "ro",
	lazy => 1,
	required => 1,
	default => sub {
		my $self = shift;
		my @attr = grep { $_->does("PRANG::Graph::Meta::Attr") }
			$self->get_all_attributes;
		my $default_xmlns = eval { $self->name->xmlns };
		my %attr_ns;
		for my $attr ( @attr ) {
			my $xmlns = $attr->has_xmlns ?
				$attr->xmlns : $default_xmlns;
			my $xml_name = $attr->has_xml_name ?
				$attr->xml_name : $attr->name;
			$attr_ns{$xmlns//""}{$xml_name} = $attr;
		}
		\%attr_ns;
	};

has 'xml_elements' =>
	isa => "ArrayRef[PRANG::Graph::Meta::Element]",
	is => "ro",
	lazy => 1,
	required => 1,
	default => sub {
		my $self = shift;
		my @elements = grep {
			$_->does("PRANG::Graph::Meta::Element")
		} $self->get_all_attributes;
		my @e_c = map { $_->associated_class->name } @elements;
		my %e_c_does;
		for my $parent ( @e_c ) {
			for my $child ( @e_c ) {
				if ( $parent eq $child ) {
					$e_c_does{$parent}{$child} = 0;
				}
				else {
					$e_c_does{$parent}{$child} =
						( $child->does($parent)
							  ? 1 : -1 );
				}
			}
		}
		[ map { $elements[$_] } sort {
			$e_c_does{$e_c[$a]}{$e_c[$b]} or
				($elements[$a]->insertion_order
					 <=> $elements[$b]->insertion_order)
			} 0..$#elements ];
	};

has 'graph' =>
	is => "rw",
	isa => "PRANG::Graph::Node",
	lazy => 1,
	required => 1,
	default => sub {
		$_[0]->build_graph;
	},
	;

method build_graph( ) {
	my @nodes = map { $_->graph_node } @{ $self->xml_elements };
	if ( @nodes != 1 ) {
		PRANG::Graph::Seq->new(
			members => \@nodes,
		       );
	}
	elsif ( @nodes ) {
		$nodes[0];
	}
}

sub add_to_list($$) {
	if ( !defined $_[0] ) {
		$_[0] = $_[1];
	}
	else {
		if ( (ref($_[0])||"") ne "ARRAY" ) {
			$_[0] = [ $_[0] ];
		}
		push @{ $_[0] }, $_[1];
	}
}

sub as_listref($) {
	if ( ref($_[0]) eq "ARRAY" ) {
		$_[0]
	}
	else {
		[ $_[0] ];
	}
}

sub as_item($) {
	if ( ref($_[0]) eq "ARRAY" ) {
		die scalar(@{$_[0]})." item(s) found where 1 expected";
	}
	else {
		$_[0];
	}
}

method accept_attributes( ArrayRef[XML::LibXML::Attr] $node_attr, PRANG::Graph::Context $context ) {

	my $attributes = $self->xml_attr;
	my %rv;
	# process attributes
	for my $attr ( @$node_attr ) {
		my $prefix = $attr->prefix;
		if ( !defined $prefix ) {
			$prefix = "";
		}
		if ( length $prefix and !exists $context->xsi->{$prefix} ) {
			$context->exception("unknown xmlns prefix '$prefix'");
		}
		my $xmlns = $context->get_xmlns($prefix);
		$xmlns //= "";
		my $meta_att = $attributes->{$xmlns}{$attr->localname};
		my $xmlns_att_name;
		my $_xmlns_att_name = sub {
			$xmlns_att_name = $meta_att->xmlns_attr
				or $context->exception(
			"xmlns wildcarded, but no xmlns_attr set on "
				.$self->name." property '"
					.$meta_att->att_name."'",
			       );
		};

		if ( $meta_att ) {
			# sweet, it's ok
			my $att_name = $meta_att->name;
			add_to_list($rv{$att_name}, $attr->value);
		}
		elsif ( $meta_att = $attributes->{"*"}{$attr->localname} ) {
			# wildcard xmlns only; need to store the xmlns
			# in another attribute.  Also, multiple values
			# may appear with different xml namespaces.
			my $att_name = $meta_att->name;
			$_xmlns_att_name->();
			add_to_list($rv{$att_name}, $attr->value);
			add_to_list($rv{$xmlns_att_name}, $xmlns);
		}
		elsif ( $meta_att = $attributes->{$xmlns}{"*"} ) {
			# wildcard attribute name.  This attribute gets
			# HashRef treatment.
			$rv{$meta_att->name}{$attr->localname} = $attr->value;
		}
		elsif ( $meta_att = $attributes->{"*"}{"*"} ) {
			# wildcard attribute name and namespace.  Both
			# attributes gets the joy of HashRef[ArrayRef[Str]|Str]
			my $att_name = $meta_att->name;
			$_xmlns_att_name->();
			add_to_list(
				$rv{$att_name}{$attr->localname},
				$attr->value,
			       );
			add_to_list(
				$rv{$xmlns_att_name}{$attr->localname},
				$xmlns
			       );
		}
		else {
			# fail.
			$context->exception("invalid attribute '".$attr->name."'");
		}
	};
	(%rv);
}

method accept_childnodes( ArrayRef[XML::LibXML::Node] $childNodes, PRANG::Graph::Context $context ) {
	my $graph = $self->graph;

	my (%init_args, %init_arg_names, %init_arg_xmlns);
	my @rv;
	my @nodes = grep { !( $_->isa("XML::LibXML::Text")
				      and $_->data =~ /\A\s*\Z/) }
		@$childNodes;
	while ( my $input_node = shift @nodes ) {
		next if $input_node->nodeType == XML_COMMENT_NODE;
		my ($key, $value, $name, $xmlns) =
			$graph->accept($input_node, $context);
		if ( !$key ) {
			my (@what) = $graph->expected($context);
			$context->exception(
				"unexpected node: expecting @what",
				$input_node,
			       );
		}
		add_to_list($init_args{$key}, $value);
		if ( defined $name ) {
			add_to_list(
				$init_arg_names{$key},
				$name,
			       );
		}
		if ( defined $xmlns ) {
			add_to_list(
				$init_arg_xmlns{$key},
				$xmlns,
			       );
		}
	}

	if ( !$graph->complete($context) ) {
		my (@what) = $graph->expected($context);
		$context->exception(
			"Node incomplete; expecting: @what",
			);
	}
	# now, we have to take all the values we just got and
	# collapse them to init args
	for my $element ( @{ $self->xml_elements } ) {
		my $key = $element->name;
		next unless exists $init_args{$key};
		my $expect;
		if ( $element->has_xml_max and $element->xml_max == 1 ) {
			$expect = \&as_item;
		}
		else {
			$expect = \&as_listref;
		}
		push @rv, eval {
			( ( ( $element->has_xml_nodeName_attr and
				      exists $init_arg_names{$key} )
				    ? ( $element->xml_nodeName_attr =>
						$expect->($init_arg_names{$key})) : ()
					       ),
			  ( ( $element->has_xmlns_attr and
				      exists $init_arg_xmlns{$key} )
				    ? ( $element->xmlns_attr =>
						$expect->($init_arg_xmlns{$key})) : ()
					       ),
			  $key => $expect->(delete $init_args{$key}),
			 );
		} or $context->exception(
			"internal error: processing '$key' attribute: $@",
		       );
	}
	if (my @leftovers = keys %init_args) {
		$context->exception(
		"internal error: ".@leftovers
			." init arg(s) left over (@leftovers)",
		       );
	}
	return @rv;
}

method marshall_in_element( XML::LibXML::Node $node, PRANG::Graph::Context $ctx ) {
	my @node_attr = grep { $_->isa("XML::LibXML::Attr") }
		$node->attributes;
	my @ns_attr = $node->getNamespaces;

	if ( @ns_attr ) {
		$ctx->add_xmlns($_->declaredPrefix//"" => $_->declaredURI)
			for @ns_attr;
	}

	my $new_ctx = $ctx->next_ctx(
		$node->namespaceURI,
		$node->localname,
	       );

	my @init_args = $self->accept_attributes( \@node_attr, $new_ctx );

	# now process elements
	my @childNodes = grep {
		!($_->isa("XML::LibXML::Comment") or
			$_->isa("XML::LibXML::Text") and $_->data =~ /\A\s+\Z/)
	} $node->childNodes;

	push @init_args, $self->accept_childnodes( \@childNodes, $new_ctx );

	my $value = eval { $self->name->new( @init_args ) };
	if ( !$value ) {
		$ctx->exception(
			"Validation error from ".$self->name
				." constructor: $@)",
			$node,
		       );
	}
	else {
		return $value;
	}
}

method add_xml_attr( Object $item, XML::LibXML::Element $node, PRANG::Graph::Context $ctx ) {
	my $attributes = $self->xml_attr;
	while ( my ($xmlns, $att) = each %$attributes ) {
		while ( my ($attName, $meta_att) = each %$att ) {
			my $is_optional;
			my $obj_att_name = $meta_att->name;
			if ( $meta_att->has_xml_required ) {
				$is_optional = !$meta_att->xml_required;
			}
			elsif ( ! $meta_att->is_required ) {
				# it's optional
				$is_optional = 1;
			}
			# we /could/ use $meta_att->get_value($item)
			# here, but I consider that to break
			# encapsulation
			my $value = $item->$obj_att_name;
			my $xml_att_name = $attName;
			if ( $meta_att->has_xml_name ) {
				my $method = $meta_att->has_xmlns_attr;
				$xml_att_name = $attName;
			}
			if ( $meta_att->has_xmlns_attr ) {
				my $method = $meta_att->xmlns_attr;
				$xmlns = $item->$method;
			}
			if ( !defined $value ) {
				die "could not serialize $item; slot "
					.$meta_att->name." empty"
						unless $is_optional;
				next;
			}

			my $emit_att = sub {
				my ($xmlns, $name, $value) = @_;
				my $prefix;
				if ( $xmlns ) {
					$prefix = $ctx->get_prefix(
						$xmlns, $item, $node,
					       );
					if ( length $prefix ) {
						$prefix .= ":";
					}
				}
				else {
					$prefix = "";
				}
				$node->setAttribute(
					$prefix.$name, $value,
				       );
			};

			my $do_array = sub {
				my $att_name = shift;
				my $array = shift;
				my $xmlns = shift;
				for ( my $i = 0; $i <= $#$array; $i++ ) {
					$emit_att->(
						$xmlns&&$xmlns->[$i],
						$att_name,
						$array->[$i],
					       );
				}
			};

			if ( ref $value eq "HASH" ) {
				# wildcarded attribute name case
				while ( my ($att, $val) = each %$value ) {
					my $att_xmlns;
					if ( $xmlns ) {
						$att_xmlns = $xmlns->{$att};
					}
					# now, we can *still* have arrays here..
					if ( ref $val eq "ARRAY" ) {
						$do_array->(
							$att, $val,
							$att_xmlns,
						       );
					}
					else {
						$emit_att->(
							$att_xmlns,
							$att, $val,
						       );
					}
				}
			}
			elsif ( ref $value eq "ARRAY" ) {
				$do_array->(
					$xml_att_name,
					$value,
					$xmlns,
				       );
			}
			else {
				$emit_att->( $xmlns, $xml_att_name, $value );
			}
		}
	}
}

method to_libxml( Object $item, XML::LibXML::Element $node, PRANG::Graph::Context $ctx ) {
	$self->add_xml_attr($item, $node, $ctx);
	$self->graph->output($item, $node, $ctx);
}

package Moose::Meta::Class::Custom::Trait::PRANG;
sub register_implementation { "PRANG::Graph::Meta::Class" }

1;

__END__

=head1 NAME

PRANG::Graph::Meta::Class - metaclass metarole for PRANG-enabled classes

=head1 SYNOPSIS

 package MyClass;
 use Moose;
 use PRANG::Graph;

 # - or -
 package MyClass;
 use Moose -traits => ["PRANG"];

 # - or -
 package MyClass;
 use Moose;
 PRANG::Graph::Meta::Class->meta->apply(__PACKAGE__->meta);

=head1 DESCRIPTION

This role effectively defines class properties and methods for PRANG
classes' meta objects.  ie, the methods it defines are all to be found
in C<YourClass-E<gt>meta>, not C<YourClass>.

The 

=head1 ATTRIBUTES

=over

=item B<HashRef[HashRef[PRANG::Graph::Meta::Attr]] xml_attr>

This read-only property maps from XML namespace and localname to a
L<PRANG::Graph::Meta::Attr> object, defining the type of that
attribute and other things described on its perldoc.

The first time it is accessed, it is built - so be sure to carry out
any run-time meta magic before parsing or emitting objects of that
type.

=item B<ArrayRef[PRANG::Graph::Meta::Element] xml_elements>

This contains an ordered list of all of the XML elements which exist
in this class.  See L<PRANG::Graph::Meta::Element>.

Like C<xml_attr>, the first time it is accessed it is built.  There
are currently some problems with ordering and role composition; as the
ordering of elements is returned from a moose accessor, but when
composing roles into classes, they are applied in any order.

=item B<PRANG::Graph::Node graph>

The C<graph> property is the acceptor and emitter for the child nodes
of this class.  See L<PRANG::Graph::Node> for the low-down.  This is
constructed by a transform on the B<xml_elements> property.

=back

=head1 METHODS

=head2 B<accept_attributes(\@node_attr, $ctx)>

=head2 B<accept_childnodes(\@childNodes, $ctx)>

=head2 B<marshall_in_element($node, $ctx)>

These methods are the parsing machinery, their API is quite subject to
change.

=head2 B<add_xml_attr($item, $node, $ctx)>

=head2 B<to_libxml($item, $node, $ctx)>

Similarly, these are the emitting methods.

=head1 SEE ALSO

L<PRANG::Graph::Meta::Attr>, L<PRANG::Graph::Meta::Element>,
L<PRANG::Graph::Node>

=head1 AUTHOR AND LICENCE

Development commissioned by NZ Registry Services, and carried out by
Catalyst IT - L<http://www.catalyst.net.nz/>

Copyright 2009, 2010, NZ Registry Services.  This module is licensed
under the Artistic License v2.0, which permits relicensing under other
Free Software licenses.

=cut

