import React, { useState, useEffect } from 'react'
import { supabase } from './supabase'

function App() {
    const [posts, setPosts] = useState([])
    const [title, setTitle] = useState('')
    const [content, setContent] = useState('')
    const [writer, setWriter] = useState('')

    const fetchPosts = async () => {
        const { data, error } = await supabase
            .from('complaints')
            .select('*')
            .order('created_at', { ascending: false })

        if (error) {
            console.error('불러오기 에러:', error)
        } else {
            setPosts(data || [])
        }
    }

    useEffect(() => {
        fetchPosts()
    }, [])

    const handleSubmit = async (e) => {
        e.preventDefault()
        if (!title || !content || !writer) {
            alert('모든 항목을 입력해주세요!')
            return
        }

        const { error } = await supabase
            .from('complaints')
            .insert([{ title, content, writer }])

        if (error) {
            alert('등록 중 오류가 발생했습니다.')
            console.error(error)
        } else {
            setTitle('')
            setContent('')
            setWriter('')
            fetchPosts()
        }
    }

    return (
        <div style={{ maxWidth: '600px', margin: '40px auto', padding: '20px', fontFamily: 'sans-serif' }}>
            <h2>민원 게시판</h2>

            <form onSubmit={handleSubmit} style={{ display: 'flex', flexDirection: 'column', gap: '10px', marginBottom: '30px' }}>
                <input
                    type="text"
                    placeholder="작성자 이름"
                    value={writer}
                    onChange={(e) => setWriter(e.target.value)}
                    style={{ padding: '8px' }}
                />
                <input
                    type="text"
                    placeholder="제목"
                    value={title}
                    onChange={(e) => setTitle(e.target.value)}
                    style={{ padding: '8px' }}
                />
                <textarea
                    placeholder="내용을 입력하세요"
                    value={content}
                    onChange={(e) => setContent(e.target.value)}
                    rows="4"
                    style={{ padding: '8px' }}
                />
                <button type="submit" style={{ padding: '10px', backgroundColor: '#4CAF50', color: 'white', border: 'none', cursor: 'pointer' }}>
                    글 등록하기
                </button>
            </form>

            <hr />

            <h3>게시글 목록</h3>
            {posts.length === 0 ? (
                <p>등록된 게시글이 없습니다.</p>
            ) : (
                posts.map((post) => (
                    <div key={post.id} style={{ border: '1px solid #ddd', padding: '15px', marginBottom: '10px', borderRadius: '5px' }}>
                        <h4 style={{ margin: '0 0 10px 0' }}>{post.title}</h4>
                        <p style={{ margin: '0 0 10px 0' }}>{post.content}</p>
                        <small style={{ color: '#666' }}>
                            작성자: {post.writer} | {new Date(post.created_at).toLocaleString()}
                        </small>
                    </div>
                ))
            )}
        </div>
    )
}

export default App