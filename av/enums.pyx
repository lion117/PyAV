
try:
    import copyreg
except ImportError:
    import copy_reg as copyreg


cdef sentinel = object()


cdef class EnumType(type):

    cdef _init(self, name, items, bint is_flags, bint allow_multi_flags, bint allow_user_create):

        self.name = name

        self.names = ()
        self.values = ()
        self._by_name = {}
        self._by_value = {}
        self._all = []

        self.is_flags = bool(is_flags)
        self.allow_multi_flags = allow_multi_flags
        self.allow_user_create = allow_user_create

        for name, value in items:
            self._create(name, value)

    cdef _create(self, name, value, by_value_only=False):

        item = self(sentinel, name, value)

        self._by_value[value] = item

        if not by_value_only:
            setattr(self, name, item)
            self._all.append(item)
            self._by_name[name] = item
            self.names += (name, )
            self.values += (value, )

        return item

    def __len__(self):
        return len(self._all)

    def __iter__(self):
        return iter(self._all)

    def __getitem__(self, key):
        if isinstance(key, basestring):
            return self._by_name[key]
        if isinstance(key, int):
            try:
                return self._by_value[key]
            except KeyError:
                if not self.allow_multi_flags:
                    raise
                try:
                    return self._get_multi_flags(key)
                except ValueError:
                    raise KeyError(key)
        if isinstance(key, self):
            return key
        raise TypeError("Uncomparable to {}.".format(self.name), key)

    cdef _get(self, long value, bint create=False):

        try:
            return self._by_value[value]
        except KeyError:
            pass

        if not create:
            return

        return self._create('{}_{}'.format(self.name.upper(), value), value, by_value_only=True)

    cdef _get_multi_flags(self, long value):

        try:
            return self._by_value[value]
        except KeyError:
            pass

        if not self.allow_multi_flags:
            raise ValueError("Missing flag in {}.".format(self.__name__), value)

        flags = []
        cdef long to_find = value
        for item in self:
            if item.value & to_find:
                flags.append(item)
                to_find = to_find ^ item.value
                if not to_find:
                    break
        if to_find:
            raise ValueError("Could not build combo in {}.".format(self.__name__, value))

        name = '|'.join(f.name for f in flags)
        cdef EnumFlag combo = self._create(name, value, by_value_only=True)
        combo.flags = tuple(flags)

        return combo

    def get(self, key, default=None, create=False):
        try:
            return self[key]
        except KeyError:
            if create:
                if not self.allow_user_create:
                    raise ValueError("Cannot create {}.".format(self.name))
                return self._get(key, create=True)
            return default


def _unpickle(mod_name, cls_name, item_name):
    mod = __import__(mod_name, fromlist=['.'])
    cls = getattr(mod, cls_name)
    return cls[item_name]
copyreg.constructor(_unpickle)


cdef class EnumItem(object):

    cdef readonly str name
    cdef readonly int value
    cdef long _hash

    def __cinit__(self, sentinel_, name, value):

        if sentinel_ is not sentinel:
            raise RuntimeError("Cannot instantiate {}.".format(self.__class__.__name__))
        self.name = name
        self.value = value

        # Establish a hash that doesn't collide with anything that would return
        # true from __eq__.
        hash_ = id(self)
        name_hash = hash(name)
        value_hash = hash(value)
        while hash_ == name_hash or hash_ == value_hash:
            hash_ += 1
        self._hash = hash_

    def __repr__(self):
        return '<{}:{}({})>'.format(self.__class__.__name__, self.name, self.value)

    def __str__(self):
        return self.name

    def __int__(self):
        return self.value

    def __hash__(self):
        return self._hash

    def __reduce__(self):
        return (_unpickle, (self.__class__.__module__, self.__class__.__name__, self.name))

    def __eq__(self, other):

        if isinstance(other, basestring):
            if self.name == other:
                return True
            if other in (<EnumType>self.__class__)._by_name:
                return False
            raise ValueError("Name not in {}.".format(self.__class__.__name__), other)

        if isinstance(other, int):
            if self.value == other:
                return True
            if other in (<EnumType>self.__class__)._by_value:
                return False
            raise ValueError("Value not in {}.".format(self.__class__.__name__), other)

        if isinstance(other, self.__class__):
            return self is other

        raise TypeError("Uncomparable to {}.".format(self.__class__.__name__), other)

    def __ne__(self, other):
        return not (self == other)


cdef class EnumFlag(EnumItem):

    cdef readonly tuple flags

    def __cinit__(self, sentinel, name, value):
        self.flags = (self, )

    def __and__(self, other):
        if not isinstance(other, int):
            other = self.__class__[other].value
        value = self.value & other
        return (<EnumType>self.__class__)._get_multi_flags(value)

    def __or__(self, other):
        if not isinstance(other, int):
            other = self.__class__[other].value
        value = self.value | other
        return (<EnumType>self.__class__)._get_multi_flags(value)

    def __xor__(self, other):
        if not isinstance(other, int):
            other = self.__class__[other].value
        value = self.value ^ other
        return (<EnumType>self.__class__)._get_multi_flags(value)

    def __invert__(self):
        # This can't result in a flag, but is helpful.
        return ~self.value


cpdef EnumType define_enum(name, items, bint is_flags=False, bint allow_multi_flags=False, bint allow_user_create=False):

    if is_flags:
        base_cls = EnumFlag
    else:
        base_cls = EnumItem

    cdef EnumType cls = EnumType(name, (base_cls, ), {})
    cls._init(name, items,
        is_flags=is_flags,
        allow_multi_flags=allow_multi_flags,
        allow_user_create=allow_user_create,
    )

    return cls

